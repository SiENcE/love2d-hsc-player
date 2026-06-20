-- opl3.lua — LuaJIT FFI binding to the Nuked-OPL3 emulator (via native/opl3.dll).
--
-- This is the real, cycle-accurate YMF262 (OPL3) chip.  HSC targets the OPL2
-- (YM3812); the OPL3 is a strict superset and, in its default power-on state,
-- behaves exactly like an OPL2, so the driver simply writes OPL2 registers.
--
-- Build the DLL with:  powershell -ExecutionPolicy Bypass -File native/build.ps1
-- (requires a 64-bit MinGW gcc; the DLL bitness must match love.exe — x64).
--
-- The DLL load is deferred to OPL3.new() and raises a catchable error if the
-- library is missing, so audioSystem can fall back to the software synth.

local ffi = require("ffi")

ffi.cdef[[
    void* hsc_opl_alloc(void);
    void  hsc_opl_free(void* chip);
    void  hsc_opl_reset(void* chip, uint32_t samplerate);
    void  hsc_opl_write(void* chip, uint16_t reg, uint8_t value);
    void  hsc_opl_write_buffered(void* chip, uint16_t reg, uint8_t value);
    void  hsc_opl_generate(void* chip, int16_t* buf, uint32_t numframes);
]]

-- ── Lazy DLL load ────────────────────────────────────────────────────────────
-- Try the bare name first (working directory / system path), then an absolute
-- path built from the game source folder.  Raises (catchable) if neither works.
local C
local function lib()
    if C then return C end
    local ok, l = pcall(ffi.load, "opl3")
    if not ok then
        local base = love.filesystem.getSource()
        local sep  = package.config:sub(1, 1)
        ok, l = pcall(ffi.load, base .. sep .. "opl3")
    end
    if not ok then error("opl3 native library not found: " .. tostring(l), 0) end
    C = l
    return C
end

local OPL3 = {}
OPL3.__index = OPL3

function OPL3.new(samplerate)
    local c = lib()                      -- may raise if the DLL is unavailable
    local self = setmetatable({}, OPL3)
    self.samplerate = samplerate
    self.chip = ffi.gc(c.hsc_opl_alloc(), c.hsc_opl_free)
    if self.chip == nil then error("hsc_opl_alloc failed (out of memory?)") end
    c.hsc_opl_reset(self.chip, samplerate)
    return self
end

function OPL3:reset()
    C.hsc_opl_reset(self.chip, self.samplerate)
end

-- Register write used by the driver.  BUFFERED on purpose: Nuked is
-- hardware-accurate and treats the key bit as a level, not an edge, so a
-- back-to-back key-off/key-on (how HSC retriggers every note) must have a
-- generated sample between them or the attack never restarts.  Buffered writes
-- reproduce the real OPL bus write-delay and are applied during generation.
function OPL3:writeReg(reg, value)
    C.hsc_opl_write_buffered(self.chip, reg, value)
end

-- Immediate write (only used for one-time init where spacing is irrelevant).
function OPL3:writeImmediate(reg, value)
    C.hsc_opl_write(self.chip, reg, value)
end

-- Render `frames` stereo frames (interleaved L,R int16) into the FFI pointer.
function OPL3:generate(ptr, frames)
    C.hsc_opl_generate(self.chip, ptr, frames)
end

return OPL3
