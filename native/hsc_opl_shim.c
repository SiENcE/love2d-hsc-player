/* hsc_opl_shim.c — thin C wrapper around Nuked-OPL3.
 *
 * Purpose: expose an opaque, void*-based API so the LuaJIT FFI layer never has
 * to mirror the (large, version-sensitive) `opl3_chip` struct layout.  The chip
 * is heap-allocated here; Lua only ever holds the opaque pointer.
 *
 * Built into opl3.dll together with opl3.c (see native/build.ps1).
 */
#include <stdlib.h>
#include <stdint.h>
#include "opl3.h"

#ifdef _WIN32
#define HSC_EXPORT __declspec(dllexport)
#else
#define HSC_EXPORT
#endif

/* Allocate and zero a chip.  Returns NULL on failure. */
HSC_EXPORT void *hsc_opl_alloc(void)
{
    return calloc(1, sizeof(opl3_chip));
}

HSC_EXPORT void hsc_opl_free(void *chip)
{
    free(chip);
}

/* Reset the chip and set the internal resampler to `samplerate` Hz. */
HSC_EXPORT void hsc_opl_reset(void *chip, uint32_t samplerate)
{
    OPL3_Reset((opl3_chip *)chip, samplerate);
}

/* Immediate register write (reg is the full 9-bit OPL3 address: bit 8 = bank). */
HSC_EXPORT void hsc_opl_write(void *chip, uint16_t reg, uint8_t value)
{
    OPL3_WriteReg((opl3_chip *)chip, reg, value);
}

/* Buffered register write: queues the write so it is applied DURING generation,
 * spaced OPL_WRITEBUF_DELAY samples after the previous buffered write.  This
 * reproduces the real OPL bus write-delay, which is essential for note
 * retriggering: a back-to-back key-off then key-on must have at least one
 * generated sample between them, or the (level-triggered) envelope generator
 * never sees the key-off and the attack fails to restart. */
HSC_EXPORT void hsc_opl_write_buffered(void *chip, uint16_t reg, uint8_t value)
{
    OPL3_WriteRegBuffered((opl3_chip *)chip, reg, value);
}

/* Generate `numframes` stereo frames (interleaved L,R int16) into buf. */
HSC_EXPORT void hsc_opl_generate(void *chip, int16_t *buf, uint32_t numframes)
{
    OPL3_GenerateStream((opl3_chip *)chip, buf, numframes);
}
