# love2d-hsc-player
A HSC Player fully made in Love2D (Lua)

---

### Cannot Fix (require deeper redesign)

1. **No real OPL2 emulator** — `audioSystem.lua` is a software FM approximation. Accurate timbre requires emulating the YM3812 (waveform shaping, tremolo/vibrato LFOs, envelope non-linearity, etc.).
2. **Waveform select** (bytes 10/11 → OPL `0xE3`/`0xE0`): half-sine, abs-sine, quarter-sine variants are ignored; only sine is used.
3. **KSL (Key Scale Level)** — bytes 3/4 bits 7:6 should attenuate high notes more steeply; not emulated.
4. **Modulator ADSR** — bytes 6/8 (modulator AR/DR/SL/RR) are ignored; only the carrier envelope drives amplitude.
5. **Percussion mode audio** (mode6) — channels 6–8 need separate drum synthesis (bass drum, hi-hat, cymbal) via the `0xBD` register; the software synth has no equivalent.
6. **TL byte XOR at load** (lines 113–117 of `hscplayer.lua`) — the `setinstr()` body isn't in the provided `hsc.cpp`, so whether this bit-swap of KSL values is correct is unverifiable.
7. **Fade-in volume not wired to audio** — `ch.state.volume` is updated in the player but `main.lua` doesn't pass it to `audioSystem.channels[i].volume`. Requires a one-liner addition once you decide on the scaling approach.
