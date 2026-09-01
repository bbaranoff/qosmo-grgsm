/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "qemu/osdep.h"
#include "hw/arm/calypso/calypso_trf6151.h"

#define SYSTEM_INHERENT_GAIN    71
#define TRF6151_FE_GAIN_LOW      7
#define TRF6151_FE_GAIN_HIGH    27
#define TRF6151_VGA_GAIN_MIN    14
#define RX_VGA_GAIN_SHIFT       11

#define TRF6151_REG_RX           0
#define TRF6151_REG_ADDR_MASK    0x7

#define TRF6151_REG_RX_RESET    0x9E00
#define TRF6151_TSP_DEV          1

static uint16_t g_reg_rx = TRF6151_REG_RX_RESET;

static int trf6151_gain_from_reg(uint16_t reg_rx)
{
    int gain = 0;
    unsigned vga;

    switch ((reg_rx >> 9) & 3) {
    case 0: gain += TRF6151_FE_GAIN_LOW;  break;
    case 3: gain += TRF6151_FE_GAIN_HIGH; break;
    default:   break;
    }

    vga = (reg_rx >> RX_VGA_GAIN_SHIFT) & 0x1f;
    if (vga < 6) {
        vga = 6;
    }
    gain += TRF6151_VGA_GAIN_MIN + (int)(vga - 6) * 2;

    return gain;
}

void calypso_trf6151_tsp_write(uint8_t dev_idx, uint32_t word)
{
    if (dev_idx != TRF6151_TSP_DEV) {
        return;
    }
    if ((word & TRF6151_REG_ADDR_MASK) != TRF6151_REG_RX) {
        return;
    }
    g_reg_rx = (uint16_t)word;
}

int calypso_trf6151_total_gain_db(void)
{
    return SYSTEM_INHERENT_GAIN + trf6151_gain_from_reg(g_reg_rx);
}

uint16_t calypso_trf6151_apm_for_rf(int target_rf_dbm)
{
    int total_gain = calypso_trf6151_total_gain_db();
    int bb_dbm = target_rf_dbm + total_gain;
    int apm;

    if (bb_dbm < 0) {
        bb_dbm = 0;
    }
    apm = bb_dbm * 64;
    if (apm > 0xFFFF) {
        apm = 0xFFFF;
    }
    return (uint16_t)apm;
}
