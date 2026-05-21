-- HSC Player in LÖVE
-- Ported from ChscPlayer (hsc.cpp) and validated against the HSC File Format
-- Spec by Simon Peter.  Fixes applied (C++ bugs → spec corrections):
--
-- From hsc.cpp comparison:
--   1. storeInstr: removed early-return guard (always re-apply, like C++)
--   2. storeInstr: slide is NOT initialised from instrument data; accumulated
--      by pitch-slide effects and reset only on a new note
--   3. Frequency formula: finetune (instr[inst][12]) and accumulated slide are
--      both added (C++: Fnr = note_table[note%12] + instr[inst][11] + slide)
--   4. Pitch-slide effects (0x10/0x20): removed spurious +1; fnum update only
--      when no note is present on the row (C++: if(!note) setfreq(...))
--   5. Volume effects (0xA0/0xB0/0xC0): AM/VIB flag bits (bits 6-7) preserved
--      from instrument TL byte (C++: vol | (instr[...][2] & ~63))
--   6. Added missing 0xD0 position-jump effect
--   7. Instrument-set: uses bit.band(note, 0x80) so all note bytes with bit 7
--      set trigger the command, not only exactly 0x80
--   8. Arrangement check moved to start of processed row; always consumes all
--      51 orderlist bytes to keep the file pointer correctly aligned
--
-- From HSC spec (new fixes):
--   9.  NoteToFnum: corrected to spec's exact table
--         {363,385,408,432,458,485,514,544,577,611,647,686}
--       Old table started at 342 (not in spec) and was missing 686, shifting
--       every note lookup by one semitone.
--  10.  Finetune (byte 12): spec says "signed; add to frequency". The finetune
--       is the HIGH NIBBLE (bits 7-4), treated as a 4-bit signed value (-8..+7).
--       Range ≈ ±0.36 semitones — correct for a fine-tune field.
--       Previous wrong "fix" used the full byte as signed -128..127, turning
--       raw 0x77 into finetune=119 (+5.4 semitones!) on most instruments.
--  11.  Orderlist is exactly 51 bytes (spec offset 1536, size 51).  Old code
--       read only 50, misaligning the file pointer for all pattern data.
--  12.  Instrument number from note byte: spec says "low 6 bits" → mask 0x3F.
--       Old code used 0x7F (7 bits), potentially selecting instruments 64-127
--       when only instruments 0-63 are reachable via this command.

local HSCPlayer = {}

-- Frequency-number lookup table (one entry per semitone, 12 total).
-- Taken verbatim from the HSC spec:
--   const unsigned short note_table[12] = {363,385,408,432,458,485,514,544,577,611,647,686};
-- The previous table was wrong: it started at 342 (not in the spec) and was
-- missing 686 (the B note), shifting every note lookup by one semitone.
local NoteToFnum = {363, 385, 408, 432, 458, 485, 514, 544, 577, 611, 647, 686}

-- Spec: "Any HSC module is played back at a fixed timer rate of 18.2Hz
-- (the standard rate, so no timer reprogram is needed)."
-- One tick = one OPL interrupt ≈ 54.945 ms.
-- LOVE calls love.update(dt) at ~60 fps which is ~3.3× too fast without this.
local TICK_PERIOD = 1 / 18.2   -- seconds per OPL timer tick

-- ── Playback state ──────────────────────────────────────────────────────────
HSCPlayer.state = {
    songpos   = 0,     -- current position in the orders/song array
    pattern   = 0,     -- current pattern number (derived from orders[songpos])
    pattpos   = 0,     -- current row within the pattern (0-63)
    speed     = 2,
    del       = 1,     -- countdown to next row (mirrors C++ `del`)
    songend   = false,
    pattbreak = 0,     -- pending pattern-break / position-jump counter
    tickAccum = 0,     -- real-time accumulator for 18.2 Hz tick pacing
    -- Percussion / fade-in state (mirrors C++ mode6, bd, fadein)
    mode6     = false, -- 6-voice percussion mode; toggled by effects 05/06
    bd        = 0,     -- shadow of OPL 0xBD register (percussion trigger bits)
    fadein    = 0,     -- fade-in counter: set to 31 by effect 03, decrements each tick
}

-- ── Per-channel state ───────────────────────────────────────────────────────
HSCPlayer.channels = {}
for i = 1, 9 do
    HSCPlayer.channels[i] = {
        instr             = 0,
        -- freq: the raw OPL frequency number (Fnr in C++), updated by note
        --       play, pitch-slide effects, finetune, and accumulated slide.
        freq              = 0,
        -- octave: ((note/12) & 7) << 2, ready for the OPL 0xB0 register.
        octave            = 0,
        -- slide: accumulated pitch offset; reset to 0 on every new note.
        slide             = 0,
        -- Combined fnum for display (freq | octave<<8); not used for OPL writes.
        fnum              = 0,
        tlCarrier         = 0,
        tlModulator       = 0,
        updateFnum        = false,
        updateTlCarrier   = false,
        updateTlModulator = false,
        state = {
            note           = 0,
            active         = false,
            noteTriggered  = false,
            instrumentName = "",
            volume         = 100,
            cell           = "... 00",
            fxDesc         = "NullFx",
        }
    }
end

HSCPlayer.instr    = {}
HSCPlayer.patterns = {}
-- orders[]: 0-indexed, exactly 50 entries matching C++ song[0..49]
HSCPlayer.orders   = {}

-- ── File loader ─────────────────────────────────────────────────────────────
function HSCPlayer:load(filename)
    local file = love.filesystem.newFile(filename)
    if not file:open("r") then
        error("Could not open file: " .. filename)
    end

    -- 128 instruments × 12 bytes each
    for i = 1, 128 do
        self.instr[i] = {}
        for j = 1, 12 do
            self.instr[i][j] = file:read(1):byte()
        end
        -- Mirror bit 6 into bit 7 for the carrier and modulator TL bytes
        -- (identical to the xor in the original C++ driver)
        self.instr[i][3] = bit.bxor(self.instr[i][3],
            bit.lshift(bit.band(self.instr[i][3], 0x40), 1))
        self.instr[i][4] = bit.bxor(self.instr[i][4],
            bit.lshift(bit.band(self.instr[i][4], 0x40), 1))
        -- Byte 12: finetune.
        -- Spec: "finetune (signed; add to frequency)".
        -- The finetune is packed in the HIGH NIBBLE of byte 12 (bits 7-4).
        -- Range is 0-15 as a 4-bit signed value:  0-7 = fine-tune up (+0..+7),
        -- 8-15 = fine-tune down (-8..-1).  The smallest semitone step in the
        -- note_table is 22 Fnum units, so the max shift of ±8 is ±0.36 semitones,
        -- which is exactly what a fine-tune field should do.
        --
        -- Previous wrong "fix": treated the whole byte as a signed -128..127 value.
        -- That turned raw byte 0x77 (instruments 2-6 in this song) into finetune=119,
        -- shifting every note by 5+ semitones and making everything sound detuned.
        --
        -- Previous original code: bit.rshift(data[12], 4) → correct nibble, but
        -- unsigned (0-15). Now we also apply the 4-bit signed conversion.
        local nibble = bit.rshift(self.instr[i][12], 4)   -- extract high nibble
        self.instr[i][12] = nibble < 8 and nibble or (nibble - 16)  -- 4-bit signed
    end

    -- FIX 3: The spec defines the orderlist as exactly 51 bytes (offset 1536,
    -- size 51).  We must consume all 51 bytes from the file so the read pointer
    -- lands correctly at the start of the pattern data.  Only the first 50
    -- entries (indices 0-49) are used for playback (C++ wraps with % 50);
    -- the 51st byte is always 0xFF (end-of-list sentinel) and is discarded.
    for i = 0, 50 do
        local b = file:read(1)
        if not b or #b == 0 then break end
        if i <= 49 then          -- only store the 50 usable entries
            self.orders[i] = b:byte()
        end
        -- index 50 is the mandatory 0xFF sentinel; read and discard it
    end

    -- Read all remaining bytes as packed pattern data
    local patternData = file:read()
    local pos         = 1
    local patternIndex = 0
    -- Each pattern: 64 rows × 9 channels × 2 bytes = 1152 bytes
    while pos + (64 * 9 * 2) - 1 <= #patternData do
        self.patterns[patternIndex] = {}
        for row = 0, 63 do
            for channel = 0, 8 do
                local note   = patternData:byte(pos)
                local effect = patternData:byte(pos + 1)
                self.patterns[patternIndex][row * 9 + channel] =
                    { note = note or 0, effect = effect or 0 }
                pos = pos + 2
            end
        end
        patternIndex = patternIndex + 1
    end

    file:close()

    -- Initialise channels 0-8 each to instrument i (mirrors C++ rewind())
    for i = 0, 8 do
        self:storeInstr(i, i)
    end
end

-- ── Pretty-printers (debug helpers, logic unchanged) ────────────────────────
local function getMIDINoteName(noteNumber)
    if noteNumber == nil or noteNumber == 0 then return "..." end
    local noteNames = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
    local octave    = math.floor(noteNumber / 12) + 1
    return string.format("%s%d", noteNames[(noteNumber % 12) + 1], octave)
end

function HSCPlayer:prettyPrintPatternsToFile(filename)
    local file = io.open(filename, "w")
    if not file then error("Could not open file for writing: " .. filename) end
    for patternIndex, pattern in pairs(self.patterns) do
        file:write(string.format("Pattern %d:\n", patternIndex))
        for row = 0, 63 do
            for channel = 0, 8 do
                local cell   = pattern[row * 9 + channel]
                local note   = getMIDINoteName(cell.note)
                local effect = (cell.effect and cell.effect ~= 0 and
                    string.format("%02X", cell.effect)) or "..."
                file:write(string.format("%s %s\t", note, effect))
            end
            file:write("\n")
        end
        file:write("\n")
    end
    file:close()
end

function HSCPlayer:prettyPrintInstrToFile(filename)
    local function tableToString(tbl, indent)
        indent = indent or 0
        local keys = {}
        for k in pairs(tbl) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if type(a) == "number" and type(b) == "number" then return a < b
            else return tostring(a) < tostring(b) end
        end)
        local result = "{\n"
        for _, key in ipairs(keys) do
            local value = tbl[key]
            result = result .. string.rep("  ", indent + 1) .. tostring(key) .. " = "
            if type(value) == "table" then
                result = result .. tableToString(value, indent + 1)
            elseif type(value) == "string" then
                result = result .. string.format("%q", value)
            else
                result = result .. tostring(value)
            end
            result = result .. ",\n"
        end
        return result .. string.rep("  ", indent) .. "}"
    end
    local file = io.open(filename, "w")
    if not file then error("Could not open file for writing: " .. filename) end
    file:write("Instruments:\n")
    file:write("HSCPlayer.instr = " .. tableToString(self.instr) .. "\n\n")
    file:close()
end

function HSCPlayer:prettyPrintOrdersToFile(filename)
    local file = io.open(filename, "w")
    if not file then error("Could not open file for writing: " .. filename) end
    file:write("Orders:\n")
    for i = 0, 49 do
        if self.orders[i] then
            file:write(string.format("Order %d: %d\n", i, self.orders[i]))
        end
    end
    file:close()
end

-- ── storeInstr ───────────────────────────────────────────────────────────────
-- Apply instrument data to a channel.
--
-- FIX 1: The early-return guard (`if instr == same then return end`) has been
--         removed.  C++ always re-applies the instrument (OPL register writes
--         are unconditional), so Lua must too.
-- FIX 2: slide is NOT touched here.  In C++ slide accumulates through pitch-
--         slide effects and is reset only when a new note is played (see the
--         `if(note) channel[chan].slide = 0` guard in update()).
function HSCPlayer:storeInstr(chan, instr)
    self.channels[chan + 1].instr = instr
    self.channels[chan + 1].state.instrumentName = string.format("Instrument %d", instr)

    local data = self.instr[instr + 1]
    if not data then return end

    -- Lua index 3 = C++ instr[...][2] = carrier TL byte
    -- Lua index 4 = C++ instr[...][3] = modulator TL byte
    self.channels[chan + 1].tlCarrier         = data[3]
    self.channels[chan + 1].updateTlCarrier   = true
    self.channels[chan + 1].tlModulator       = data[4]
    self.channels[chan + 1].updateTlModulator = true
end

-- ── rewind ───────────────────────────────────────────────────────────────────
-- Reset playback to the beginning (mirrors ChscPlayer::rewind).
function HSCPlayer:rewind()
    self.state.songpos   = 0
    self.state.pattern   = 0
    self.state.pattpos   = 0
    self.state.pattbreak = 0
    self.state.speed     = 2
    self.state.del       = 1
    self.state.songend   = false
    self.state.tickAccum = 0

    for i = 0, 8 do
        local ch = self.channels[i + 1]
        ch.freq              = 0
        ch.octave            = 0
        ch.slide             = 0
        ch.fnum              = 0
        ch.state.note        = 0
        ch.state.active      = false
        ch.state.noteTriggered = false
        ch.state.volume      = 100
        ch.state.cell        = "... 00"
        ch.state.fxDesc      = "NullFx"
        self:storeInstr(i, i)
    end
    self.state.mode6  = false
    self.state.bd     = 0
    self.state.fadein = 0
end

-- ── update ───────────────────────────────────────────────────────────────────
-- Call from love.update(dt) every frame.
--
-- SPEED FIX: Spec mandates "a fixed timer rate of 18.2 Hz (the standard rate)."
-- Each call advances the real-time accumulator by `dt` seconds; only when a
-- full 18.2 Hz tick (~54.9 ms) has elapsed does the player's `del` counter
-- decrement and (when del reaches 0) a pattern row get processed.
-- Without this, LÖVE's ~60 fps call rate would run the music ~3.3× too fast.
-- Omitting `dt` forces one raw tick through unconditionally (useful for tests).
--
-- Returns true while still playing, false once the song has ended.
function HSCPlayer:update(dt)

    -- ── 18.2 Hz real-time gate ───────────────────────────────────────────────
    if dt ~= nil then
        self.state.tickAccum = self.state.tickAccum + dt
        if self.state.tickAccum < TICK_PERIOD then
            return not self.state.songend  -- not a full tick yet; do nothing
        end
        self.state.tickAccum = self.state.tickAccum - TICK_PERIOD
        -- any residual time carries forward naturally to the next call
    end

    -- ── Fade-in counter: decrement once per tick (mirrors C++ `if(fadein) fadein--`) ──
    if self.state.fadein > 0 then
        self.state.fadein = self.state.fadein - 1
    end

    -- ── Speed / timing (mirrors C++ `del--; if(del) return !songend;`) ──────
    self.state.del = self.state.del - 1
    if self.state.del > 0 then
        return not self.state.songend
    end

    -- ── Arrangement / pattern selection ──────────────────────────────────────
    local pattnr = self.orders[self.state.songpos]
    if pattnr == nil then
        self.state.songend = true
        return false
    end

    if pattnr >= 0xB2 then
        -- Values >= 0xB2 (including 0xFF) signal end-of-song / corrupt data
        self.state.songend = true
        self.state.songpos = 0
        pattnr = self.orders[0] or 0
    elseif bit.band(pattnr, 0x80) ~= 0 and pattnr <= 0xB1 then
        -- Jump marker: low 7 bits encode the destination songpos
        self.state.songpos = bit.band(pattnr, 0x7F)
        self.state.pattpos = 0
        pattnr = self.orders[self.state.songpos] or 0
        self.state.songend = true
    end

    self.state.pattern = pattnr

    -- ── Process all 9 channels for the current row ─────────────────────────
    local pattoff = self.state.pattpos * 9

    for chan = 0, 8 do
        local ch = self.channels[chan + 1]

        -- Clear per-row visualisation state at the start of each processed row
        ch.state.noteTriggered = false
        ch.state.fxDesc        = "NullFx"
        if ch.state.note == -1 then ch.state.note = 0 end

        local patternRow = self.patterns[pattnr]
        if not patternRow then goto continue end

        local cell = patternRow[pattoff + chan]
        if not cell then goto continue end

        local note   = cell.note
        local effect = cell.effect or 0

        -- ── FIX 4: Instrument-set uses low 6 bits per spec ───────────────
        -- Spec: "If bit 7 is set, it's not a note, but an instrument to be
        --        set (low 6 bits)."  Old code used 0x7F (7 bits) by mistake.
        if bit.band(note, 0x80) ~= 0 then
            local instrNum = bit.band(effect, 0x3F)
            self:storeInstr(chan, instrNum)
            ch.state.cell = string.format("III %02X", instrNum)
            goto continue
        end

        local eff_op     = bit.band(effect, 0x0F)
        local effectType = bit.band(effect, 0xF0)
        local inst       = ch.instr

        -- FIX 3 (partial): Reset accumulated slide whenever a note is present.
        -- C++: `if(note) channel[chan].slide = 0;` (before the effect switch).
        if note ~= 0 then
            ch.slide = 0
        end

        -- ── Effect handling ────────────────────────────────────────────────
        if effectType == 0x00 then
            -- Global effects
            if eff_op == 1 then
                ch.state.fxDesc      = "PatternBreak"
                self.state.pattbreak = self.state.pattbreak + 1
            elseif eff_op == 3 then
                -- Fade-in: volume ramps from near-silent to full over 31 ticks.
                -- C++: fadein = 31 → each tick: setvolume(chan, fadein*2, fadein*2)
                ch.state.fxDesc  = "FadeIn"
                self.state.fadein = 31
            elseif eff_op == 5 then
                -- 6-voice percussion mode ON (channels 6-8 become drums)
                ch.state.fxDesc  = "PercMode ON"
                self.state.mode6 = true
            elseif eff_op == 6 then
                -- 6-voice percussion mode OFF
                ch.state.fxDesc  = "PercMode OFF"
                self.state.mode6 = false
            end

        elseif effectType == 0x10 then
            -- FIX 4: Pitch slide UP — no spurious +1; only update fnum when
            -- there is no note on this row (C++: `if(!note) setfreq(…)`).
            ch.state.fxDesc = "PitchSlideUp"
            ch.freq  = ch.freq  + eff_op
            ch.slide = ch.slide + eff_op
            if note == 0 then ch.updateFnum = true end

        elseif effectType == 0x20 then
            -- FIX 4: Pitch slide DOWN — same corrections as 0x10.
            ch.state.fxDesc = "PitchSlideDown"
            ch.freq  = ch.freq  - eff_op
            ch.slide = ch.slide - eff_op
            if note == 0 then ch.updateFnum = true end

        elseif effectType == 0x50 then
            -- Set percussion instrument — unimplemented (as in C++)
            do end

        elseif effectType == 0x60 then
            -- Set feedback — OPL register write only; no Lua-side state needed
            do end

        elseif effectType == 0xA0 then
            -- FIX 5: Set carrier volume, preserving AM/VIB flags (bits 6-7).
            -- C++: `vol | (instr[channel[chan].inst][2] & ~63)`
            --       Lua index [3] = C++ index [2] (carrier TL byte).
            ch.state.fxDesc = "SetCarrierVol"
            local instrData = self.instr[inst + 1]
            if instrData then
                ch.tlCarrier      = bit.bor(
                    bit.lshift(eff_op, 2),
                    bit.band(instrData[3], 0xC0))   -- preserve AM/VIB flags
                ch.updateTlCarrier = true
            end

        elseif effectType == 0xB0 then
            -- VOLUME FIX: Set modulator volume.
            -- In FM (non-additive) synthesis the modulator shapes the carrier's
            -- timbre; its TL controls harmonic depth, NOT loudness.  Overwriting
            -- it with a volume-scaled value distorts the sound and makes it thin
            -- or nearly silent.  Only in ADDITIVE mode (instrument byte 9 bit 0
            -- = 1) does the modulator contribute directly to the OPL output, so
            -- only then is it valid to treat its TL as a volume register.
            -- C++ writes the register unconditionally (a known quirk); we match
            -- the INTENDED semantics of the effect: modulator volume in additive,
            -- no-op in FM mode.
            ch.state.fxDesc = "SetModulatorVol"
            local instrData = self.instr[inst + 1]
            if instrData and bit.band(instrData[9], 1) ~= 0 then
                -- Additive mode only: modulator adds to output → valid volume.
                ch.tlModulator       = bit.bor(
                    bit.lshift(eff_op, 2),
                    bit.band(instrData[4], 0xC0))   -- preserve KSL flags
                ch.updateTlModulator = true
            end
            -- FM mode: intentionally leave tlModulator unchanged.

        elseif effectType == 0xC0 then
            -- FIX 5: Set instrument volume (carrier, and optionally modulator).
            -- C++: carrier always; modulator only when instr[inst][8] & 1 (additive).
            --       Lua index [9] = C++ index [8] (connection/additive flag).
            ch.state.fxDesc = "SetVolume"
            local instrData = self.instr[inst + 1]
            if instrData then
                local db = bit.lshift(eff_op, 2)
                ch.tlCarrier      = bit.bor(db, bit.band(instrData[3], 0xC0))
                ch.updateTlCarrier = true
                if bit.band(instrData[9], 1) ~= 0 then   -- additive synthesis
                    ch.tlModulator       = bit.bor(db, bit.band(instrData[4], 0xC0))
                    ch.updateTlModulator = true
                end
            end

        elseif effectType == 0xD0 then
            -- FIX 6: Position jump (was completely absent in original Lua).
            -- C++: `pattbreak++; songpos = eff_op; songend = 1;`
            -- The pattbreak handler then increments songpos by one more, so
            -- the effective destination is eff_op + 1 (replicates C++ exactly).
            ch.state.fxDesc      = "PosJump"
            self.state.pattbreak = self.state.pattbreak + 1
            self.state.songpos   = eff_op
            self.state.songend   = true

        elseif effectType == 0xF0 then
            -- Set speed (del = ++speed in C++ means speed becomes eff_op+1)
            ch.state.fxDesc  = "SetSpeed"
            self.state.speed = eff_op + 1
            self.state.del   = self.state.speed
        end

        -- ── Fade-in volume: scale channel toward full volume as fadein counts down ──
        -- C++: if(fadein) setvolume(chan, fadein*2, fadein*2)
        -- fadein*2 is used as a TL attenuation value (0=loud, 62=near-silent).
        -- We expose this as a 0-100 volume so the audio layer can scale mixing.
        if self.state.fadein > 0 then
            ch.state.volume = 100 - math.floor(self.state.fadein * 2 * 100 / 62)
        end

        -- ── Note handling ─────────────────────────────────────────────────
        if note == 0 then
            ch.state.cell = string.format("... %02X", effect)
            goto continue
        end

        note = note - 1   -- convert to 0-based (mirrors C++ `note--`)

        -- Pause (raw 0x7F → 0x7E after decrement) or out-of-range octave.
        -- C++ check: `(note == 0x7f-1) || ((note/12) & ~7)`
        -- `(note/12) & ~7` is non-zero when octave > 7.
        if note == 0x7E or math.floor(note / 12) > 7 then
            ch.state.note  = -1       -- marks key-off / pause
            ch.updateFnum  = true
            ch.state.cell  = string.format("Pau %02X", effect)
            goto continue
        end

        -- ── FIX 3: Play note with finetune and accumulated slide ──────────
        -- Spec:  frequency = note_table[note%12] + instrument_finetune + slide
        -- C++:   Fnr = note_table[note%12] + instr[inst][11] + channel[chan].slide
        -- Lua index [12] = C++ index [11] (signed finetune byte, converted at load).
        do
            local instrData = self.instr[inst + 1]
            local finetune  = instrData and instrData[12] or 0

            ch.freq   = NoteToFnum[note % 12 + 1] + finetune + ch.slide
            -- Octave in OPL 0xB0 format: bits 2-4 = (oct & 7)
            ch.octave = bit.lshift(bit.band(math.floor(note / 12), 7), 2)
            ch.updateFnum          = true
            ch.state.note          = note
            ch.state.active        = true
            -- In percussion mode (mode6), channels 6-8 (0-indexed) are drums.
            -- C++ does NOT set the key-on bit via 0xB0 for these; it triggers
            -- them via the 0xBD register instead.  We suppress noteTriggered so
            -- the audio layer doesn't retrigger the FM voice as a melodic note.
            ch.state.noteTriggered = not (self.state.mode6 and chan >= 6)

            local noteNames = {"C-","C#","D-","D#","E-","F-","F#","G-","G#","A-","A#","B-"}
            ch.state.cell = string.format(
                "%s%d %02X",
                noteNames[note % 12 + 1],
                math.floor(note / 12) + 1,
                effect)
        end

        ::continue::
    end -- for chan

    -- ── Advance speed counter ────────────────────────────────────────────────
    self.state.del = self.state.speed

    -- ── Advance song / pattern position ─────────────────────────────────────
    -- Mirrors C++ post-row handling exactly, including the pattbreak path.
    if self.state.pattbreak > 0 then
        self.state.pattpos   = 0
        self.state.pattbreak = 0
        self.state.songpos   = (self.state.songpos + 1) % 50
        if self.state.songpos == 0 then
            self.state.songend = true
        end
    else
        self.state.pattpos = (self.state.pattpos + 1) % 64
        if self.state.pattpos == 0 then
            self.state.songpos = (self.state.songpos + 1) % 50
            if self.state.songpos == 0 then
                self.state.songend = true
            end
        end
    end

    -- ── Update derived visualisation state ──────────────────────────────────
    for i = 0, 8 do
        local ch = self.channels[i + 1]

        if ch.updateFnum then
            ch.updateFnum = false
            -- Combine freq and octave into a single display value.
            -- ch.octave = (oct & 7) << 2, so octave<<8 places it at bits 10-12.
            ch.fnum = ch.freq + bit.lshift(ch.octave, 8)
        end

        if ch.updateTlCarrier then
            ch.updateTlCarrier = false
            -- TL attenuation: bits 0-5 (0 = loudest, 63 = silent)
            ch.state.volume = 100 - bit.band(ch.tlCarrier, 0x3F) * 100 / 0x3F
        end

        if ch.updateTlModulator then
            ch.updateTlModulator = false
        end
    end

    return not self.state.songend
end

return HSCPlayer
