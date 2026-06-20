-- audioSystem.lua — OPL-backed audio backend.
--
-- Owns an OPL backend and pumps its stereo output into a LÖVE queueable source.
-- The HSC driver writes OPL registers through audioSystem.write().  The backend
-- is the real Nuked-OPL3 chip when native/opl3.dll is available, and the
-- software FM approximation (softopl.lua) otherwise — both share one interface,
-- so the driver is unaffected by which is in use.

local ffi  = require("ffi")
local OPL3 = require("opl3")
local SoftOPL = require("softopl")

local audioSystem = {}
audioSystem.sampleRate = 44100
audioSystem.backend    = "none"   -- "opl3" | "software"

-- Frames per queued buffer.  1024 stereo frames ≈ 23 ms at 44.1 kHz.
local FRAMES = 1024

-- ── Set up the backend and the LÖVE audio plumbing ──────────────────────────
function audioSystem.init()
    local ok, chip = pcall(OPL3.new, audioSystem.sampleRate)
    if ok and chip then
        audioSystem.chip    = chip
        audioSystem.backend = "opl3"
    else
        audioSystem.chip    = SoftOPL.new(audioSystem.sampleRate)
        audioSystem.backend = "software"
        print("[audioSystem] Nuked-OPL3 DLL unavailable; using software FM fallback.")
        print("              reason: " .. tostring(chip))
    end

    audioSystem.queueSource =
        love.audio.newQueueableSource(audioSystem.sampleRate, 16, 2)

    -- A single reusable stereo buffer; the backend renders directly into its bytes.
    audioSystem.sndData = love.sound.newSoundData(FRAMES, audioSystem.sampleRate, 16, 2)
    audioSystem.ptr     = ffi.cast("int16_t*", audioSystem.sndData:getFFIPointer())

    audioSystem.resetChip()
end

-- Reset the backend and apply the OPL2-style init sequence (mirrors hsc.cpp
-- rewind(): enable waveform select, clear NTS/percussion).
function audioSystem.resetChip()
    audioSystem.chip:reset()
    audioSystem.chip:writeReg(0x01, 0x20)  -- WSE: enable waveform-select registers
    audioSystem.chip:writeReg(0x08, 0x00)  -- NTS off
    audioSystem.chip:writeReg(0xBD, 0x00)  -- rhythm/percussion off
end

-- Register write entry point used by the HSC driver.
function audioSystem.write(reg, value)
    audioSystem.chip:writeReg(reg, value)
end

-- ── Render one buffer from the backend and queue it ─────────────────────────
function audioSystem.generateAndQueueAudio()
    audioSystem.chip:generate(audioSystem.ptr, FRAMES)
    audioSystem.queueSource:queue(audioSystem.sndData)
end

-- ── Called from love.update ──────────────────────────────────────────────────
function audioSystem.update()
    -- Keep every free buffer filled so playback never underruns.
    while audioSystem.queueSource:getFreeBufferCount() > 0 do
        audioSystem.generateAndQueueAudio()
    end

    if not audioSystem.queueSource:isPlaying() then
        audioSystem.queueSource:play()
    end
end

return audioSystem
