/*
 * gps_acq.h - PS-side driver for the GPS L1 acquisition core (hw/rtl/gps_acq_axi.sv)
 *
 * Bare-metal (Xilinx standalone BSP) by default.  Register access goes through
 * ACQ_RD / ACQ_WR so the driver can be retargeted (Linux UIO, unit-test stub).
 */
#ifndef GPS_ACQ_H
#define GPS_ACQ_H

#include <stdint.h>

/* ---------------------------------------------------------------- register map */
#define ACQ_CTRL        0x00u   /* R/W bit0 start, bit1 soft reset, bit2 irq enable   */
#define ACQ_STATUS      0x04u   /* R   bit0 busy, bit1 done, bit2 detected            */
#define ACQ_PRN         0x08u   /* R/W satellite to search, 1..32                      */
#define ACQ_THRESH      0x0Cu   /* R/W peak / second-peak threshold, Q8.8 (2.0=0x200)  */
#define ACQ_DOPPLER     0x10u   /* R   Doppler bin k, signed, 1 kHz units              */
#define ACQ_CODE_PHASE  0x14u   /* R   code phase, 0..1023 samples                     */
#define ACQ_PEAK        0x18u   /* R   peak power P1                                   */
#define ACQ_SECOND      0x1Cu   /* R   second-peak power P2                            */
#define ACQ_CYCLES      0x20u   /* R   clock cycles of the last search                 */
#define ACQ_EXPONENT    0x24u   /* R   block exponent (debug)                          */
#define ACQ_ID          0x28u   /* R   0x47505331 "GPS1"                               */

#define ACQ_CTRL_START      (1u << 0)
#define ACQ_CTRL_SOFT_RESET (1u << 1)
#define ACQ_CTRL_IRQ_EN     (1u << 2)
#define ACQ_STATUS_BUSY     (1u << 0)
#define ACQ_STATUS_DONE     (1u << 1)
#define ACQ_STATUS_DETECTED (1u << 2)

#define ACQ_ID_VALUE        0x47505331u
#define ACQ_N_PRN           32
#define ACQ_WORDS_PER_MS    1024          /* 4096 3-bit samples, 4 per 32-bit word */
#define ACQ_SAMPLES_PER_CHIP (1.024e6 / 1.023e6)
#define ACQ_THRESH_Q8_8(x)  ((uint32_t)((x) * 256.0 + 0.5))

/* ---------------------------------------------------------------- register access */
#ifndef ACQ_RD
#include "xil_io.h"
#define ACQ_RD(base, off)       Xil_In32((base) + (off))
#define ACQ_WR(base, off, val)  Xil_Out32((base) + (off), (val))
#endif

/* ---------------------------------------------------------------- types */
typedef struct {
    int      prn;
    int      detected;
    int      doppler_hz;        /* bin centre, Hz                         */
    int      code_phase;        /* samples (1.024 MHz), 0..1023           */
    double   code_phase_chips;
    uint32_t peak;
    uint32_t second;
    double   ratio;             /* peak / second peak                     */
    uint32_t cycles;
} acq_result_t;

typedef struct {
    uintptr_t base;             /* AXI4-Lite base address (from xparameters.h) */
    uint32_t  thresh_q8_8;
} acq_dev_t;

/* ---------------------------------------------------------------- API */
int  acq_init(acq_dev_t *dev, uintptr_t base, double threshold);
void acq_soft_reset(const acq_dev_t *dev);
void acq_start(const acq_dev_t *dev, int prn, int irq_enable);
int  acq_is_done(const acq_dev_t *dev);
void acq_read_result(const acq_dev_t *dev, int prn, acq_result_t *res);
/* blocking search of one PRN on the samples currently in the capture buffer */
int  acq_search(const acq_dev_t *dev, int prn, acq_result_t *res);
/* search PRN 1..32; returns the number of satellites detected */
int  acq_search_all(const acq_dev_t *dev, acq_result_t res[ACQ_N_PRN]);

/* status report to the flight controller: proprietary NMEA sentence
 *   $PGACQ,<prn>,<det>,<doppler_hz>,<code_phase_chips>,<ratio>*CS\r\n           */
int  acq_format_nmea(const acq_result_t *res, char *buf, int len);

#endif /* GPS_ACQ_H */
