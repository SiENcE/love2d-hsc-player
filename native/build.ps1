# Build opl3.dll (Nuked-OPL3 + HSC shim) for use via LuaJIT FFI in LÖVE.
#
# Requires a 64-bit MinGW gcc (the DLL bitness MUST match love.exe — LÖVE 11.5
# is x64).  MSYS2 ucrt64 works; its bin dir must be on PATH so gcc's helper
# binaries (cc1) can resolve their DLLs.
#
# Usage (from repo root):  powershell -ExecutionPolicy Bypass -File native/build.ps1
$ErrorActionPreference = "Stop"

$mingwBin = "C:\msys64\ucrt64\bin"
if (Test-Path $mingwBin) { $env:PATH = "$mingwBin;$env:PATH" }

$root   = Split-Path -Parent $PSScriptRoot
$nuked  = Join-Path $root "Nuked-OPL3"
$out    = Join-Path $root "opl3.dll"

$args = @(
    "-O3", "-shared", "-static-libgcc", "-DNDEBUG",
    "-I", $nuked,
    "-o", $out,
    (Join-Path $nuked "opl3.c"),
    (Join-Path $PSScriptRoot "hsc_opl_shim.c")
)

Write-Host "gcc $($args -join ' ')"
& gcc @args
if ($LASTEXITCODE -ne 0) { throw "gcc failed ($LASTEXITCODE)" }
Write-Host "Built $out"
