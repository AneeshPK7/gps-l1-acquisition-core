/*
 * gps_acq.c - PS-side driver for the GPS L1 acquisition core
 * Implements the control routine of report Section 5.2.
 */
#include <stdio.h>
#include "gps_acq.h"

int acq_init(acq_dev_t *dev, uintptr_t base, double threshold)
{
    dev->base = base;
    dev->thresh_q8_8 = ACQ_THRESH_Q8_8(threshold);
    if (ACQ_RD(base, ACQ_ID) != ACQ_ID_VALUE)
        return -1;                                   /* core not found */
    acq_soft_reset(dev);
    ACQ_WR(base, ACQ_THRESH, dev->thresh_q8_8);
    return 0;
}

void acq_soft_reset(const acq_dev_t *dev)
{
    ACQ_WR(dev->base, ACQ_CTRL, ACQ_CTRL_SOFT_RESET);
}

void acq_start(const acq_dev_t *dev, int prn, int irq_enable)
{
    ACQ_WR(dev->base, ACQ_PRN, (uint32_t)prn);                 /* select satellite */
    ACQ_WR(dev->base, ACQ_THRESH, dev->thresh_q8_8);
    ACQ_WR(dev->base, ACQ_CTRL,
           ACQ_CTRL_START | (irq_enable ? ACQ_CTRL_IRQ_EN : 0)); /* start search */
}

int acq_is_done(const acq_dev_t *dev)
{
    return (ACQ_RD(dev->base, ACQ_STATUS) & ACQ_STATUS_DONE) != 0;
}

void acq_read_result(const acq_dev_t *dev, int prn, acq_result_t *res)
{
    uint32_t st = ACQ_RD(dev->base, ACQ_STATUS);
    res->prn              = prn;
    res->detected         = (st & ACQ_STATUS_DETECTED) != 0;
    res->doppler_hz       = (int32_t)ACQ_RD(dev->base, ACQ_DOPPLER) * 1000;
    res->code_phase       = (int)ACQ_RD(dev->base, ACQ_CODE_PHASE);
    res->code_phase_chips = res->code_phase / ACQ_SAMPLES_PER_CHIP;
    res->peak             = ACQ_RD(dev->base, ACQ_PEAK);
    res->second           = ACQ_RD(dev->base, ACQ_SECOND);
    res->ratio            = res->second ? (double)res->peak / res->second : 0.0;
    res->cycles           = ACQ_RD(dev->base, ACQ_CYCLES);
}

int acq_search(const acq_dev_t *dev, int prn, acq_result_t *res)
{
    acq_start(dev, prn, 0);
    while (!acq_is_done(dev))
        ;                                            /* ~0.15 ms at 100 MHz */
    acq_read_result(dev, prn, res);
    return res->detected;
}

int acq_search_all(const acq_dev_t *dev, acq_result_t res[ACQ_N_PRN])
{
    int n = 0;
    for (int prn = 1; prn <= ACQ_N_PRN; prn++)
        n += acq_search(dev, prn, &res[prn - 1]);
    return n;
}

int acq_format_nmea(const acq_result_t *res, char *buf, int len)
{
    char body[80];
    int ratio10 = (int)(res->ratio * 10.0 + 0.5);
    int cp10    = (int)(res->code_phase_chips * 10.0 + 0.5);
    int n = snprintf(body, sizeof body, "PGACQ,%02d,%d,%d,%d.%d,%d.%d",
                     res->prn, res->detected, res->doppler_hz,
                     cp10 / 10, cp10 % 10, ratio10 / 10, ratio10 % 10);
    unsigned char cs = 0;
    for (int i = 0; i < n; i++)
        cs ^= (unsigned char)body[i];
    return snprintf(buf, (size_t)len, "$%s*%02X\r\n", body, cs);
}
