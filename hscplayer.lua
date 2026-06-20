-- HSC Player in LÖVE — OPL register-level driver.
--
-- This is a faithful port of ChscPlayer (AdPlug / hsc.cpp by Simon Peter),
-- driving the real Nuked-OPL3 chip via audioSystem.write().  Instead of
-- approximating FM in Lua, the player now writes the exact OPL2 registers the
-- original DOS driver wrote, so waveform select, KSL, the modulator envelope,
-- feedback and percussion mode all come for free from the emulated chip.
--
-- The chip interface is injected as `HSCPlayer.opl` (a table with `write(reg,
-- value)` and `resetChip()`); main.lua wires it to audioSystem.  Until then a
-- no-op stub is used so loading never touches a chip that isn't ready.
--
-- Register mapping (HSC instrument byte → OPL register, per the HSC spec):
--   byte1→0x23  byte2→0x20   (AM/VIB/EGT/KSR/MULT : carrier / modulator)
--   byte3→0x43  byte4→0x40   (KSL/TL)
--   byte5→0x63  byte6→0x60   (AR/DR)
--   byte7→0x83  byte8→0x80   (SL/RR)
--   byte9→0xC0  (feedback/connection)
--   byte10→0xE3 byte11→0xE0  (waveform select)
--   byte12 = signed finetune (added to the frequency number)
-- Carrier registers are modulator-base + 3; the per-channel modulator operator
-- offset is op_table[chan].

local HSCPlayer = {}

local band, bor, bxor   = bit.band, bit.bor, bit.bxor
local lshift, rshift    = bit.lshift, bit.rshift
local bnot              = bit.bnot
local format, floor     = string.format, math.floor

-- Standard AdLib operator-offset table: modulator operator register offset for
-- each of the 9 melodic channels (carrier = this + 3).  1-indexed: [chan+1].
local op_table = {0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x10, 0x11, 0x12}

-- Frequency-number lookup table (one entry per semitone), verbatim from spec.
local NoteToFnum = {363, 385, 408, 432, 458, 485, 514, 544, 577, 611, 647, 686}

local noteNames = {"C-","C#","D-","D#","E-","F-","F#","G-","G#","A-","A#","B-"}

-- Spec: fixed 18.2 Hz timer.  LÖVE calls love.update(dt) at ~60 fps, so we gate
-- the player to one OPL tick (~54.9 ms) of real time.
local TICK_PERIOD = 1 / 18.2

-- No-op chip until main.lua injects the real audio backend (keeps load() safe).
HSCPlayer.opl = { write = function() end, resetChip = function() end }

-- ── Playback state ──────────────────────────────────────────────────────────
HSCPlayer.state = {
    songpos   = 0,
    pattern   = 0,
    pattpos   = 0,
    speed     = 2,
    del       = 1,
    songend   = false,
    pattbreak = 0,
    tickAccum = 0,
    mode6     = false,   -- 6-voice percussion mode
    bd        = 0,       -- shadow of OPL 0xBD (percussion trigger bits)
    fadein    = 0,       -- fade-in counter (effect 03)
    mtkmode   = false,   -- MPU-401 Trakker note-off-by-one bug imitation
}

-- ── Per-channel state ───────────────────────────────────────────────────────
HSCPlayer.channels = {}
for i = 1, 9 do
    HSCPlayer.channels[i] = {
        instr = 0,
        freq  = 0,       -- raw OPL frequency number (Fnr)
        slide = 0,       -- accumulated pitch slide; reset on each new note
        state = {
            note           = 0,
            active         = false,
            instrumentName = "",
            cell           = "... 00",
            fxDesc         = "NullFx",
        },
    }
end

-- adl_freq[chan+1]: shadow of each channel's 0xB0 register (keyon | block | fnum-hi)
HSCPlayer.adl_freq = {0, 0, 0, 0, 0, 0, 0, 0, 0}

HSCPlayer.instr    = {}
HSCPlayer.patterns = {}
HSCPlayer.orders   = {}   -- 0-indexed, 50 usable entries

-- ── File loader (unchanged logic) ───────────────────────────────────────────
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
        -- Mirror bit 6 into bit 7 for carrier/modulator TL bytes (matches the
        -- xor in the original C++ driver's loader).
        self.instr[i][3] = bxor(self.instr[i][3], lshift(band(self.instr[i][3], 0x40), 1))
        self.instr[i][4] = bxor(self.instr[i][4], lshift(band(self.instr[i][4], 0x40), 1))
        -- Byte 12: finetune is the high nibble as a 4-bit signed value (-8..+7).
        local nibble = rshift(self.instr[i][12], 4)
        self.instr[i][12] = nibble < 8 and nibble or (nibble - 16)
    end

    -- Orderlist is exactly 51 bytes; only the first 50 are used (51st = 0xFF).
    for i = 0, 50 do
        local b = file:read(1)
        if not b or #b == 0 then break end
        if i <= 49 then
            self.orders[i] = b:byte()
        end
    end

    -- Remaining bytes = packed patterns (64 rows × 9 channels × 2 bytes).
    local patternData = file:read()
    local pos         = 1
    local patternIndex = 0
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

    -- Initialise channels 0-8 each to instrument i (mirrors C++ rewind()).
    for i = 0, 8 do
        self:setinstr(i, i)
    end
end

-- ── Pretty-printers (debug helpers, unchanged) ──────────────────────────────
local function getMIDINoteName(noteNumber)
    if noteNumber == nil or noteNumber == 0 then return "..." end
    local names  = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
    local octave = floor(noteNumber / 12) + 1
    return string.format("%s%d", names[(noteNumber % 12) + 1], octave)
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

-- ── OPL helpers (faithful ports of ChscPlayer::setinstr/setfreq/setvolume) ───

-- Program a channel with an instrument: write all 11 OPL operator/channel regs.
function HSCPlayer:setinstr(chan, insnr)
    self.channels[chan + 1].instr = insnr
    self.channels[chan + 1].state.instrumentName = format("Instrument %d", insnr)

    local ins = self.instr[insnr + 1]
    if not ins then return end

    local op  = op_table[chan + 1]
    local opl = self.opl
    opl.write(0x20 + op,   ins[2])    -- modulator AM/VIB/EGT/KSR/MULT
    opl.write(0x23 + op,   ins[1])    -- carrier
    opl.write(0x40 + op,   ins[4])    -- modulator KSL/TL
    opl.write(0x43 + op,   ins[3])    -- carrier
    opl.write(0x60 + op,   ins[6])    -- modulator AR/DR
    opl.write(0x63 + op,   ins[5])    -- carrier
    opl.write(0x80 + op,   ins[8])    -- modulator SL/RR
    opl.write(0x83 + op,   ins[7])    -- carrier
    opl.write(0xC0 + chan, ins[9])    -- feedback/connection
    opl.write(0xE0 + op,   ins[11])   -- modulator waveform
    opl.write(0xE3 + op,   ins[10])   -- carrier waveform
end

-- Set a channel's frequency number, preserving its keyon/block bits.
function HSCPlayer:setfreq(chan, freq)
    local af = bor(band(self.adl_freq[chan + 1], bnot(3)), band(rshift(freq, 8), 3))
    self.adl_freq[chan + 1] = af
    self.opl.write(0xA0 + chan, band(freq, 0xFF))
    self.opl.write(0xB0 + chan, af)
end

-- Set carrier (and, in additive mode, modulator) volume via TL, preserving the
-- instrument's KSL bits.  `volc`/`volm` are TL attenuation values (0 = loud).
function HSCPlayer:setvolume(chan, volc, volm)
    local ins = self.instr[self.channels[chan + 1].instr + 1]
    if not ins then return end
    local op = op_table[chan + 1]
    self.opl.write(0x43 + op, bor(volc, band(ins[3], bnot(63))))
    if band(ins[9], 1) ~= 0 then
        self.opl.write(0x40 + op, bor(volm, band(ins[4], bnot(63))))
    end
end

-- ── rewind ───────────────────────────────────────────────────────────────────
function HSCPlayer:rewind()
    self.state.songpos   = 0
    self.state.pattern   = 0
    self.state.pattpos   = 0
    self.state.pattbreak = 0
    self.state.speed     = 2
    self.state.del       = 1
    self.state.songend   = false
    self.state.tickAccum = 0
    self.state.mode6     = false
    self.state.bd        = 0
    self.state.fadein    = 0

    self.opl.resetChip()   -- OPL2-style chip re-init

    for i = 0, 8 do
        local ch = self.channels[i + 1]
        ch.freq                = 0
        ch.slide               = 0
        ch.state.note          = 0
        ch.state.active        = false
        ch.state.cell          = "... 00"
        ch.state.fxDesc        = "NullFx"
        self.adl_freq[i + 1]   = 0
        self:setinstr(i, i)
    end
end

-- ── update ───────────────────────────────────────────────────────────────────
-- Call from love.update(dt).  Gated to the 18.2 Hz OPL tick rate; returns true
-- while still playing.  Omitting `dt` forces one raw tick (useful for tests).
function HSCPlayer:update(dt)
    -- ── 18.2 Hz real-time gate ───────────────────────────────────────────────
    if dt ~= nil then
        self.state.tickAccum = self.state.tickAccum + dt
        if self.state.tickAccum < TICK_PERIOD then
            return not self.state.songend
        end
        self.state.tickAccum = self.state.tickAccum - TICK_PERIOD
    end

    -- ── Speed handling: del--; if still counting, no row this tick (C++ order) ──
    self.state.del = self.state.del - 1
    if self.state.del > 0 then
        return not self.state.songend
    end

    -- Fade-in decrements once per processed row (matches C++ placement).
    if self.state.fadein > 0 then
        self.state.fadein = self.state.fadein - 1
    end

    -- ── Arrangement / pattern selection ──────────────────────────────────────
    local pattnr = self.orders[self.state.songpos]
    if pattnr == nil then
        self.state.songend = true
        return false
    end
    if pattnr >= 0xB2 then
        self.state.songend = true
        self.state.songpos = 0
        pattnr = self.orders[0] or 0
    elseif band(pattnr, 0x80) ~= 0 and pattnr <= 0xB1 then
        self.state.songpos = band(pattnr, 0x7F)
        self.state.pattpos = 0
        pattnr = self.orders[self.state.songpos] or 0
        self.state.songend = true
    end
    self.state.pattern = pattnr

    -- ── Process all 9 channels for the current row ─────────────────────────
    local pattoff = self.state.pattpos * 9
    local opl     = self.opl

    for chan = 0, 8 do
        local ch = self.channels[chan + 1]
        ch.state.fxDesc = "NullFx"

        local patternRow = self.patterns[pattnr]
        local cell       = patternRow and patternRow[pattoff + chan]
        local note       = cell and cell.note or 0
        local effect     = cell and cell.effect or 0

        -- Instrument-set: bit 7 of note set → set instrument (C++ uses the
        -- effect byte as the instrument number).
        if band(note, 0x80) ~= 0 then
            local insnr = band(effect, 0x3F)
            self:setinstr(chan, insnr)
            ch.state.cell   = format("III %02X", insnr)
            ch.state.fxDesc = "SetInstr"
            goto continue
        end

        local eff_op  = band(effect, 0x0F)
        local effType = band(effect, 0xF0)
        local inst    = ch.instr
        if note ~= 0 then ch.slide = 0 end

        -- ── Effect handling ────────────────────────────────────────────────
        if effType == 0x00 then
            if eff_op == 1 then
                ch.state.fxDesc      = "PatternBreak"
                self.state.pattbreak = self.state.pattbreak + 1
            elseif eff_op == 3 then
                ch.state.fxDesc   = "FadeIn"
                self.state.fadein = 31
            elseif eff_op == 5 then
                ch.state.fxDesc  = "PercMode ON"
                self.state.mode6 = true
            elseif eff_op == 6 then
                ch.state.fxDesc  = "PercMode OFF"
                self.state.mode6 = false
            end

        elseif effType == 0x10 then
            ch.state.fxDesc = "PitchSlideUp"
            ch.freq  = ch.freq  + eff_op
            ch.slide = ch.slide + eff_op
            if note == 0 then self:setfreq(chan, ch.freq) end

        elseif effType == 0x20 then
            ch.state.fxDesc = "PitchSlideDown"
            ch.freq  = ch.freq  - eff_op
            ch.slide = ch.slide - eff_op
            if note == 0 then self:setfreq(chan, ch.freq) end

        elseif effType == 0x50 then
            -- Set percussion instrument — unimplemented (as in C++).

        elseif effType == 0x60 then
            ch.state.fxDesc = "SetFeedback"
            local d = self.instr[inst + 1]
            if d then opl.write(0xC0 + chan, bor(band(d[9], 1), lshift(eff_op, 1))) end

        elseif effType == 0xA0 then
            ch.state.fxDesc = "SetCarrierVol"
            local d = self.instr[inst + 1]
            if d then
                opl.write(0x43 + op_table[chan + 1],
                    bor(lshift(eff_op, 2), band(d[3], bnot(63))))
            end

        elseif effType == 0xB0 then
            -- Set modulator volume.  C++ writes this unconditionally; on a real
            -- chip that is the authentic behaviour (it changes the modulation
            -- index / timbre in FM mode, loudness in additive mode).
            ch.state.fxDesc = "SetModulatorVol"
            local d = self.instr[inst + 1]
            if d then
                opl.write(0x40 + op_table[chan + 1],
                    bor(lshift(eff_op, 2), band(d[4], bnot(63))))
            end

        elseif effType == 0xC0 then
            ch.state.fxDesc = "SetVolume"
            local d = self.instr[inst + 1]
            if d then
                local db = lshift(eff_op, 2)
                local op = op_table[chan + 1]
                opl.write(0x43 + op, bor(db, band(d[3], bnot(63))))
                if band(d[9], 1) ~= 0 then
                    opl.write(0x40 + op, bor(db, band(d[4], bnot(63))))
                end
            end

        elseif effType == 0xD0 then
            ch.state.fxDesc      = "PosJump"
            self.state.pattbreak = self.state.pattbreak + 1
            self.state.songpos   = eff_op
            self.state.songend   = true

        elseif effType == 0xF0 then
            ch.state.fxDesc  = "SetSpeed"
            self.state.speed = eff_op + 1
            self.state.del   = self.state.speed
        end

        -- Fade-in volume: writes TL each row while fading (C++ setvolume).
        if self.state.fadein > 0 then
            self:setvolume(chan, self.state.fadein * 2, self.state.fadein * 2)
        end

        -- ── Note handling ─────────────────────────────────────────────────
        if note == 0 then
            ch.state.cell = format("... %02X", effect)
            goto continue
        end

        note = note - 1
        if self.state.mtkmode then note = note - 1 end

        -- Pause (raw 0x7F) or out-of-range octave → clear keyon.
        if note == 0x7E or floor(note / 12) > 7 then
            self.adl_freq[chan + 1] = band(self.adl_freq[chan + 1], bnot(32))
            opl.write(0xB0 + chan, self.adl_freq[chan + 1])
            ch.state.active = false
            ch.state.cell   = format("Pau %02X", effect)
            goto continue
        end

        do
            local d        = self.instr[inst + 1]
            local finetune = d and d[12] or 0
            local Okt      = lshift(band(floor(note / 12), 7), 2)
            local Fnr      = NoteToFnum[note % 12 + 1] + finetune + ch.slide
            ch.freq = Fnr

            -- In percussion mode the drum channels (6-8) are NOT keyed via 0xB0.
            if (not self.state.mode6) or chan < 6 then
                self.adl_freq[chan + 1] = bor(Okt, 32)
            else
                self.adl_freq[chan + 1] = Okt
            end

            opl.write(0xB0 + chan, 0)   -- key off before retrigger (clean attack)
            self:setfreq(chan, Fnr)

            if self.state.mode6 then
                local bd = self.state.bd
                if chan == 6 then
                    opl.write(0xBD, band(bd, bnot(16))); bd = bor(bd, 48)   -- bass drum
                elseif chan == 7 then
                    opl.write(0xBD, band(bd, bnot(1)));  bd = bor(bd, 33)   -- hi-hat
                elseif chan == 8 then
                    opl.write(0xBD, band(bd, bnot(2)));  bd = bor(bd, 34)   -- cymbal
                end
                self.state.bd = bd
                opl.write(0xBD, bd)
            end

            ch.state.note   = note
            ch.state.active = true
            ch.state.cell   = format("%s%d %02X",
                noteNames[note % 12 + 1], floor(note / 12) + 1, effect)
        end

        ::continue::
    end

    -- ── Advance speed / song / pattern position ─────────────────────────────
    self.state.del = self.state.speed
    if self.state.pattbreak > 0 then
        self.state.pattpos   = 0
        self.state.pattbreak = 0
        self.state.songpos   = (self.state.songpos + 1) % 50
        if self.state.songpos == 0 then self.state.songend = true end
    else
        self.state.pattpos = (self.state.pattpos + 1) % 64
        if self.state.pattpos == 0 then
            self.state.songpos = (self.state.songpos + 1) % 50
            if self.state.songpos == 0 then self.state.songend = true end
        end
    end

    return not self.state.songend
end

return HSCPlayer
