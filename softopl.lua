-- softopl.lua — software FM approximation, used as a fallback when the
-- Nuked-OPL3 DLL can't be loaded.
--
-- It exposes the SAME interface as opl3.lua (new / reset / writeReg / generate),
-- so the HSC driver and audioSystem don't care which backend is active.  Instead
-- of receiving note-level calls, it DECODES the OPL register writes the driver
-- emits and approximates 2-operator FM from them: per-operator multiple, total
-- level (logarithmic), ADSR envelope, waveform select, plus feedback and the
-- FM/additive connection.  It is intentionally an approximation — accurate
-- timbre needs the real chip — but it keeps the player audible with no DLL.

local ffi = require("ffi")

local TWO_PI  = 2 * math.pi
local HALF_PI = math.pi / 2
local OPL_RATE = 49716            -- OPL sample rate, for fnum→frequency

-- Standard AdLib operator offsets per channel (modulator; carrier = +3).
local op_table = {0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x10, 0x11, 0x12}

-- offset (reg & 0x1F) → {ch = 0-based channel, car = is-carrier}
local opToCh = {}
for c = 0, 8 do
    opToCh[op_table[c + 1]]     = { ch = c, car = false }
    opToCh[op_table[c + 1] + 3] = { ch = c, car = true  }
end

local frqmul = {[0]=0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 12, 12, 15, 15}

local band, rshift = bit.band, bit.rshift

local function oplWave(form, phase)
    local s = math.sin(phase)
    if form == 0 then return s
    elseif form == 1 then return s > 0 and s or 0
    elseif form == 2 then return s >= 0 and s or -s
    else return (phase % math.pi) < HALF_PI and (s >= 0 and s or -s) or 0 end
end

local function tlToAmp(tl) return 10 ^ (-0.75 * tl / 20) end

local function rateToSec(rate)
    if rate == 0 then return 30.0 end
    return 0.001 * (2 ^ (14 - rate))
end

-- Advance an ADSR envelope one sample.  EGT (sustain) selects whether the note
-- holds at the sustain level (1) or keeps releasing through it (0, percussive).
local function advanceEnv(env, op, sr)
    local st = env.stage
    if st == "attack" then
        env.level = env.level + 1.0 / (op.ar * sr)
        if env.level >= 1.0 then env.level = 1.0; env.stage = "decay" end
    elseif st == "decay" then
        local step = (1.0 - op.sl) / (op.dr * sr)
        env.level = env.level - step
        if env.level <= op.sl then
            env.level = op.sl
            env.stage = (op.egt == 1) and "sustain" or "release"
        end
    elseif st == "release" then
        env.level = env.level - 1.0 / (op.rr * sr)
        if env.level <= 0 then env.level = 0; env.stage = "off" end
    end
    return env.level
end

local SoftOPL = {}
SoftOPL.__index = SoftOPL

local function newOperator()
    return {
        mult = 1, tl = 63, egt = 0, wf = 0,
        ar = 0.01, dr = 0.1, sl = 1.0, rr = 0.1,
        phase = 0,
        env = { stage = "off", level = 0 },
    }
end

function SoftOPL.new(samplerate)
    local self = setmetatable({}, SoftOPL)
    self.samplerate = samplerate
    self:reset()
    return self
end

function SoftOPL:reset()
    self.ch = {}
    for c = 1, 9 do
        self.ch[c] = {
            fnum = 0, block = 0, freq = 0, key = 0,
            fb = 0, con = 0, fbmem = 0,
            mod = newOperator(),
            car = newOperator(),
        }
    end
end

local function recalcFreq(ch)
    ch.freq = ch.fnum * OPL_RATE / (2 ^ (20 - ch.block))
end

function SoftOPL:writeReg(reg, val)
    if reg >= 0x100 then return end                 -- OPL3 bank unused by HSC

    if reg >= 0x20 and reg <= 0x35 then
        local m = opToCh[band(reg, 0x1F)]; if not m then return end
        local op = m.car and self.ch[m.ch + 1].car or self.ch[m.ch + 1].mod
        op.mult = frqmul[band(val, 0x0F)] or 1
        op.egt  = band(rshift(val, 5), 1)
    elseif reg >= 0x40 and reg <= 0x55 then
        local m = opToCh[band(reg, 0x1F)]; if not m then return end
        local op = m.car and self.ch[m.ch + 1].car or self.ch[m.ch + 1].mod
        op.tl = band(val, 0x3F)
    elseif reg >= 0x60 and reg <= 0x75 then
        local m = opToCh[band(reg, 0x1F)]; if not m then return end
        local op = m.car and self.ch[m.ch + 1].car or self.ch[m.ch + 1].mod
        op.ar = rateToSec(rshift(val, 4))
        op.dr = rateToSec(band(val, 0x0F))
    elseif reg >= 0x80 and reg <= 0x95 then
        local m = opToCh[band(reg, 0x1F)]; if not m then return end
        local op = m.car and self.ch[m.ch + 1].car or self.ch[m.ch + 1].mod
        op.sl = 1.0 - rshift(val, 4) / 15.0
        op.rr = rateToSec(band(val, 0x0F))
    elseif reg >= 0xE0 and reg <= 0xF5 then
        local m = opToCh[band(reg, 0x1F)]; if not m then return end
        local op = m.car and self.ch[m.ch + 1].car or self.ch[m.ch + 1].mod
        op.wf = band(val, 0x03)
    elseif reg >= 0xA0 and reg <= 0xA8 then
        local ch = self.ch[reg - 0xA0 + 1]
        ch.fnum = band(ch.fnum, 0x300) + val
        recalcFreq(ch)
    elseif reg >= 0xB0 and reg <= 0xB8 then
        local ch = self.ch[reg - 0xB0 + 1]
        ch.fnum  = band(ch.fnum, 0xFF) + band(val, 0x03) * 256
        ch.block = band(rshift(val, 2), 0x07)
        recalcFreq(ch)
        local nk = band(rshift(val, 5), 1)
        if nk == 1 and ch.key == 0 then        -- key-on edge: retrigger
            ch.mod.phase, ch.car.phase, ch.fbmem = 0, 0, 0
            ch.mod.env.stage, ch.mod.env.level = "attack", 0
            ch.car.env.stage, ch.car.env.level = "attack", 0
        elseif nk == 0 and ch.key == 1 then    -- key-off edge: release
            if ch.mod.env.stage ~= "off" then ch.mod.env.stage = "release" end
            if ch.car.env.stage ~= "off" then ch.car.env.stage = "release" end
        end
        ch.key = nk
    elseif reg >= 0xC0 and reg <= 0xC8 then
        local ch = self.ch[reg - 0xC0 + 1]
        ch.fb  = band(rshift(val, 1), 0x07)
        ch.con = band(val, 0x01)
    end
end

function SoftOPL:generate(ptr, frames)
    local sr = self.samplerate
    local chans = self.ch
    for i = 0, frames - 1 do
        local mix = 0
        for c = 1, 9 do
            local ch = chans[c]
            if ch.car.env.stage ~= "off" then
                local mod, car = ch.mod, ch.car
                local w = TWO_PI * ch.freq / sr
                local modLevel = advanceEnv(mod.env, mod, sr)
                local carLevel = advanceEnv(car.env, car, sr)

                local fbScale = ch.fb > 0 and (math.pi * (2 ^ (ch.fb - 1)) / 512) or 0
                local modRaw  = oplWave(mod.wf, mod.phase + fbScale * ch.fbmem)
                ch.fbmem = modRaw
                local modOut = modRaw * tlToAmp(mod.tl) * modLevel

                local s
                if ch.con == 0 then
                    s = oplWave(car.wf, car.phase + modOut * math.pi) * tlToAmp(car.tl) * carLevel
                else
                    s = (oplWave(car.wf, car.phase) * tlToAmp(car.tl) * carLevel + modOut) * 0.5
                end
                mix = mix + s

                mod.phase = (mod.phase + w * mod.mult) % TWO_PI
                car.phase = (car.phase + w * car.mult) % TWO_PI
            end
        end
        local v = math.tanh(mix * 0.3) * 32767
        ptr[2 * i]     = v
        ptr[2 * i + 1] = v
    end
end

return SoftOPL
