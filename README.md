# love2d-hsc-player
A HSC (HSC-Tracker / NEO Software) AdLib music player in LÖVE.

Playback is driven by the real **Nuked-OPL3** chip emulator (a cycle-accurate
YMF262) via LuaJIT FFI. The Lua side is a faithful port of AdPlug's `ChscPlayer`
that writes OPL2 registers exactly like the original DOS driver, so waveform
select, KSL, the modulator envelope, feedback and percussion mode all come
directly from the emulated chip instead of being approximated.

If the native DLL can't be loaded, the player automatically falls back to a
pure-Lua software FM approximation (`softopl.lua`) — same register interface,
lower fidelity, but no compiler required.

## Building the native chip

The emulator is compiled to `opl3.dll` (loaded by `opl3.lua` through FFI). The
DLL's architecture **must match love.exe** — LÖVE 11.5 is x64, so build with a
64-bit MinGW gcc (e.g. MSYS2 `ucrt64`):

```powershell
powershell -ExecutionPolicy Bypass -File native/build.ps1
```

This compiles `Nuked-OPL3/opl3.c` + `native/hsc_opl_shim.c` into
`opl3.dll` in the repo root. (The Nuked-OPL3 source under `Nuked-OPL3/` is
git-ignored; fetch it from https://github.com/nukeykt/Nuked-OPL3 if missing.)

## Running

```
love .
```

Space = play/pause, `r` = rewind, Esc = quit.

## Architecture

| File | Role |
|------|------|
| `hscplayer.lua` | Pattern/order/effect logic; writes OPL registers (`setinstr`/`setfreq`/`setvolume`) at the 18.2 Hz HSC tick rate. |
| `opl3.lua` | LuaJIT FFI binding to `opl3.dll` (alloc/reset/writeReg/generate). |
| `softopl.lua` | Pure-Lua software FM approximation with the same interface — fallback when the DLL is unavailable. |
| `audioSystem.lua` | Picks the backend, does the OPL2 power-on init, renders stereo audio straight into a LÖVE queueable source. |
| `native/` | C shim + build script for the Nuked-OPL3 DLL. |

### Note on register writes

OPL register writes use Nuked's **buffered** path (`OPL3_WriteRegBuffered`), not
immediate writes. HSC retriggers every note with a back-to-back key-off/key-on;
Nuked is hardware-accurate and treats the key bit as a level, so without a
generated sample between the two writes the envelope never re-attacks and most
notes come out ~30 dB too quiet. Buffered writes reproduce the real OPL bus
write-delay and fix this.

## Still TODO / known gaps

1. **OPL3 stereo / extended waveforms** are unused — the driver stays in OPL2
   compatibility mode on purpose (HSC is an OPL2 format).
2. **Set-percussion-instrument effect (`5x`)** is unimplemented, exactly as in
   the original `ChscPlayer`.
3. **Distribution** currently assumes a folder game with `opl3.dll` next to the
   `.lua` files; a fused `.love` would need the DLL placed beside `love.exe` (or
   loaded via a packaged path).
