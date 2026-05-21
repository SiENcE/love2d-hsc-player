local audioSystem = {}
audioSystem.sampleRate = 18200
audioSystem.channels = {}
audioSystem.queueSource = love.audio.newQueueableSource(audioSystem.sampleRate, 16, 1)

-- ── MIDI note → frequency ────────────────────────────────────────────────────
local function midiNoteToFrequency(note)
    return 440 * 2^((note - 69) / 12)
end

local noteFrequencies = {}
for i = 0, 127 do
    noteFrequencies[i] = midiNoteToFrequency(i)
end

-- ── OPL2 frequency-multiplier table (register index 0-15) ───────────────────
-- Source: Yamaha YM3812 datasheet, frqmul_tab in opl.c
-- {0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 12, 12, 15, 15}
local frqmul = {[0]=0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 12, 12, 15, 15}

-- ── OPL ADSR rate → approximate time in seconds ─────────────────────────────
-- OPL rate 15 = fastest (~0.5 ms), rate 1 = slowest (~8 s), rate 0 = infinite.
-- Formula: 0.001 * 2^(14 - rate)  covers the practical range well.
local function rateToSec(rate)
    if rate == 0 then return 30.0 end   -- effectively infinite hold / no release
    return 0.001 * (2 ^ (14 - rate))
end

-- ── Channel initialisation ───────────────────────────────────────────────────
function audioSystem.init()
    for i = 1, 9 do
        audioSystem.channels[i] = {
            frequency      = 0,
            volume         = 1,
            active         = false,
            modulatorPhase = 0,
            carrierPhase   = 0,
            lastSample     = 0,
            instrument = {
                -- Carrier synthesis parameters
                carrierMultiple    = 1,     -- OPL MULT (0.5–15)
                carrierTotalLevel  = 0,     -- TL 0–63 (0 = loudest, 63 = silent)
                -- Modulator synthesis parameters
                modulatorMultiple    = 1,
                modulatorTotalLevel = 63,   -- max attenuation = effectively no mod
                -- Carrier ADSR (seconds)
                attack      = 0.01,
                decay       = 0.1,
                sustainLevel = 1.0,        -- 0 = silent, 1 = full volume
                release     = 0.1,
                -- FM configuration
                feedback    = 0,    -- 0–7
                algorithm   = 0,    -- 0 = FM cascade, 1 = additive
            },
            envelope = {
                stage = "off",
                level = 0,
            }
        }
    end
end

-- ── FM sample generation ─────────────────────────────────────────────────────
local function createFMSamples(channel, numSamples)
    local channelData  = audioSystem.channels[channel]
    local inst         = channelData.instrument
    local envelope     = channelData.envelope
    local sampleRate   = audioSystem.sampleRate

    local modPhase  = channelData.modulatorPhase
    local carPhase  = channelData.carrierPhase
    local lastSample = channelData.lastSample

    -- Phase increments per sample
    local modInc = channelData.frequency * inst.modulatorMultiple * 2 * math.pi / sampleRate
    local carInc = channelData.frequency * inst.carrierMultiple   * 2 * math.pi / sampleRate

    -- Carrier amplitude from TL: 0 = full, 63 = silent  → linear 0–1
    local carAmp  = (63 - inst.carrierTotalLevel) / 63
    -- Modulator depth: 0 = full modulation, 63 = no modulation → linear 0–1
    local modDepth = (63 - inst.modulatorTotalLevel) / 63

    -- Feedback amount: OPL shifts previous sample right by (7 - feedback) bits.
    -- Approximated as a direct scale factor.
    local fbScale = inst.feedback > 0 and (math.pi * (2 ^ (inst.feedback - 1)) / 512) or 0

    local samples = {}

    for i = 1, numSamples do
        -- ── Envelope ──────────────────────────────────────────────────────
        if envelope.stage == "attack" then
            envelope.level = envelope.level + (1.0 / (inst.attack * sampleRate))
            if envelope.level >= 1.0 then
                envelope.level = 1.0
                envelope.stage = "decay"
            end

        elseif envelope.stage == "decay" then
            local target = inst.sustainLevel
            local step   = (1.0 - target) / (inst.decay * sampleRate)
            envelope.level = envelope.level - step
            if envelope.level <= target then
                envelope.level = target
                envelope.stage = "sustain"
            end

        elseif envelope.stage == "release" then
            envelope.level = envelope.level - (1.0 / (inst.release * sampleRate))
            if envelope.level <= 0 then
                envelope.level = 0
                envelope.stage = "off"
                channelData.active = false
            end
        end

        -- ── FM signal path ─────────────────────────────────────────────────
        -- Operator 1 (modulator) with self-feedback
        local modOut = math.sin(modPhase + fbScale * lastSample)

        local sample
        if inst.algorithm == 0 then
            -- FM / cascade mode: modulator modulates carrier phase
            sample = math.sin(carPhase + modOut * modDepth * math.pi)
        else
            -- Additive mode: both operators contribute directly to output
            sample = (math.sin(carPhase) + modOut * modDepth) * 0.5
        end

        lastSample      = sample * envelope.level * carAmp
        samples[i]      = lastSample

        modPhase = (modPhase + modInc) % (2 * math.pi)
        carPhase = (carPhase + carInc) % (2 * math.pi)
    end

    channelData.lastSample     = lastSample
    channelData.modulatorPhase = modPhase
    channelData.carrierPhase   = carPhase

    return samples
end

-- ── Play a note on a channel ─────────────────────────────────────────────────
-- `note`           : MIDI note number (0–127)
-- `instrumentData` : raw HSC instrument bytes, already loaded by hscplayer.lua
--   Byte  1 = OPL reg 0x23 → carrier   AM(7) VIB(6) EGT(5) KSR(4) MULT(3:0)
--   Byte  2 = OPL reg 0x20 → modulator AM(7) VIB(6) EGT(5) KSR(4) MULT(3:0)
--   Byte  3 = OPL reg 0x43 → carrier   KSL(7:6) TL(5:0)
--   Byte  4 = OPL reg 0x40 → modulator KSL(7:6) TL(5:0)
--   Byte  5 = OPL reg 0x63 → carrier   AR(7:4) DR(3:0)
--   Byte  6 = OPL reg 0x60 → modulator AR(7:4) DR(3:0)  (not used: single env)
--   Byte  7 = OPL reg 0x83 → carrier   SL(7:4) RR(3:0)
--   Byte  8 = OPL reg 0x80 → modulator SL(7:4) RR(3:0)  (not used: single env)
--   Byte  9 = OPL reg 0xC0 → feedback(3:1) connection/algorithm(0)
--   Byte 10 = OPL reg 0xE3 → carrier   waveform (not emulated)
--   Byte 11 = OPL reg 0xE0 → modulator waveform (not emulated)
--   Byte 12 = finetune: pre-processed by hscplayer.lua to a signed integer
--             in OPL fnum units (approx ±4 cents per unit at A4).
function audioSystem.playNote(channel, note, instrumentData)
    if note == nil or note < 0 or note > 127 then return end
    if not instrumentData then return end

    local channelData = audioSystem.channels[channel]
    local inst        = channelData.instrument

    -- Base frequency from MIDI note number
    channelData.frequency = noteFrequencies[note] or 0
    channelData.active    = true

    -- Reset oscillator phases for a clean note attack
    channelData.modulatorPhase = 0
    channelData.carrierPhase   = 0
    channelData.lastSample     = 0

    -- ── Carrier parameters (bytes 1, 3, 5, 7) ──────────────────────────────
    -- Byte 1 = carrier MULT/AM/VIB/EGT/KSR: multiplier in bits 3:0
    inst.carrierMultiple  = frqmul[bit.band(instrumentData[1], 0x0F)] or 1

    -- Byte 3 = carrier KSL/TL: total level (attenuation) in bits 5:0
    inst.carrierTotalLevel = bit.band(instrumentData[3], 0x3F)

    -- Byte 5 = carrier AR(7:4) / DR(3:0)
    inst.attack = rateToSec(bit.rshift(instrumentData[5], 4))
    inst.decay  = rateToSec(bit.band(instrumentData[5], 0x0F))

    -- Byte 7 = carrier SL(7:4) / RR(3:0)
    -- OPL SL: 0 = full volume during sustain, 15 = silence during sustain.
    local sl = bit.rshift(instrumentData[7], 4)
    inst.sustainLevel = 1.0 - sl / 15.0   -- convert to linear 0–1 amplitude
    inst.release      = rateToSec(bit.band(instrumentData[7], 0x0F))

    -- ── Modulator parameters (bytes 2, 4) ───────────────────────────────────
    -- Byte 2 = modulator MULT/AM/VIB/EGT/KSR: multiplier in bits 3:0
    inst.modulatorMultiple  = frqmul[bit.band(instrumentData[2], 0x0F)] or 1

    -- Byte 4 = modulator KSL/TL: total level (attenuation) in bits 5:0
    inst.modulatorTotalLevel = bit.band(instrumentData[4], 0x3F)

    -- ── FM configuration (byte 9) ────────────────────────────────────────────
    -- Byte 9 = OPL reg 0xC0: feedback level in bits 3:1, connection in bit 0
    inst.feedback  = bit.band(bit.rshift(instrumentData[9], 1), 0x07)
    inst.algorithm = bit.band(instrumentData[9], 0x01)

    -- ── Finetune (byte 12) ───────────────────────────────────────────────────
    -- hscplayer.lua pre-processes byte 12 to a signed OPL-fnum-unit offset.
    -- 1 fnum unit ≈ 0.76 Hz at A4 ≈ ~3 cents. Convert to a frequency ratio.
    local finetune = instrumentData[12] or 0   -- signed, already converted
    if channelData.frequency > 0 then
        channelData.frequency = channelData.frequency * (2 ^ (finetune * 3 / 1200))
    end

    -- Restart the envelope
    channelData.envelope.stage = "attack"
    channelData.envelope.level = 0
end

-- ── Stop (release) a note ────────────────────────────────────────────────────
function audioSystem.stopNote(channel)
    local channelData = audioSystem.channels[channel]
    if channelData.envelope.stage ~= "off" then
        channelData.envelope.stage = "release"
    end
end

-- ── Mix and queue an audio buffer ────────────────────────────────────────────
function audioSystem.generateAndQueueAudio()
    local bufferSize   = 1024
    local mixedSamples = {}
    for i = 1, bufferSize do
        mixedSamples[i] = 0
    end

    for ch, channelData in ipairs(audioSystem.channels) do
        if channelData.active or channelData.envelope.stage ~= "off" then
            local samples = createFMSamples(ch, bufferSize)
            local vol = channelData.volume
            for i = 1, bufferSize do
                mixedSamples[i] = mixedSamples[i] + samples[i] * vol
            end
        end
    end

    -- Normalise to prevent clipping when many channels are active
    local peak = 0
    for i = 1, bufferSize do
        local v = math.abs(mixedSamples[i])
        if v > peak then peak = v end
    end
    local scale = (peak > 1.0) and (1.0 / peak) or 1.0

    local audioData = love.sound.newSoundData(bufferSize, audioSystem.sampleRate, 16, 1)
    for i = 1, bufferSize do
        audioData:setSample(i - 1, mixedSamples[i] * scale)
    end

    audioSystem.queueSource:queue(audioData)
end

-- ── Called from love.update ──────────────────────────────────────────────────
function audioSystem.update()
    if audioSystem.queueSource:getFreeBufferCount() > 0 then
        audioSystem.generateAndQueueAudio()
    end

    if not audioSystem.queueSource:isPlaying() then
        audioSystem.queueSource:play()
    end
end

return audioSystem
