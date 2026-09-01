/* SPDX-License-Identifier: GPL-2.0-or-later */

#include "qemu/osdep.h"
#include "hw/irq.h"
#include "hw/sysbus.h"
#include "qemu/log.h"
#include "hw/arm/calypso/calypso_inth.h"

static CalypsoINTHState *g_inth;

static void calypso_inth_update(CalypsoINTHState *s)
{
    uint32_t active = s->levels & ~s->mask;
    int best_irq = -1, best_irq_prio = 0x7F;
    int best_fiq = -1, best_fiq_prio = 0x7F;

    for (int j = 0; j < CALYPSO_INTH_NUM_IRQS; j++) {
        int i = (s->rr_start + j) % CALYPSO_INTH_NUM_IRQS;
        if (!(active & (1u << i))) continue;
        int prio = s->ilr[i] & 0x1F;
        int is_fiq = (s->ilr[i] >> 8) & 1;
        if (is_fiq) {
            if (prio < best_fiq_prio) { best_fiq_prio = prio; best_fiq = i; }
        } else {
            if (prio < best_irq_prio) { best_irq_prio = prio; best_irq = i; }
        }
    }

    if (best_irq >= 0) {
        s->ith_v = best_irq;
        qemu_irq_raise(s->parent_irq);
    } else {
        if (best_fiq < 0) s->ith_v = 0;
        qemu_irq_lower(s->parent_irq);
    }

    if (best_fiq >= 0) {
        s->fiq_v = best_fiq;
        qemu_irq_raise(s->parent_fiq);
    } else {
        qemu_irq_lower(s->parent_fiq);
    }
}

static void calypso_inth_set_irq(void *opaque, int irq, int level)
{
    CalypsoINTHState *s = CALYPSO_INTH(opaque);

    if (irq == 6  ) {
        static unsigned sim_log;
        if (sim_log++ < 60)
            fprintf(stderr,
                    "[INTH] LINE-SET sim(6) level=%d  mask=0x%08x  "
                    "bit6_masked=%d  prev_levels=0x%08x  ilr[6]=0x%04x\n",
                    level, s->mask,
                    !!(s->mask & (1u<<6)), s->levels, s->ilr[6]);
    }

    if (level) {
        s->levels |= (1u << irq);
    } else {
        s->levels &= ~(1u << irq);
    }

    calypso_inth_update(s);
}

void calypso_inth_arm_ack(void);
void calypso_inth_arm_ack(void)
{
    CalypsoINTHState *s = g_inth;
    if (!s) return;

    uint16_t svc = s->ith_v;
    if (svc > 0 || (s->levels & 1)) {
        s->levels &= ~(1u << svc);
        s->rr_start = (svc + 1) % CALYPSO_INTH_NUM_IRQS;
    }
    s->irq_in_service = -1;

    {
        static unsigned _n = 0;
        if (_n++ < 40)
            fprintf(stderr, "[INTH] ARM-ACK #%u svc=%u levels=0x%08x mask=0x%08x "
                    "(new IRQ agreement, depuis le DSP)\n",
                    _n, svc, s->levels, s->mask);
    }
    calypso_inth_update(s);
}

static uint64_t calypso_inth_read(void *opaque, hwaddr offset, unsigned size)
{
    CalypsoINTHState *s = CALYPSO_INTH(opaque);

    switch (offset) {
    case 0x00:
        return s->levels & 0xFFFF;
    case 0x02:
        return (s->levels >> 16) & 0xFFFF;
    case 0x08:
        return s->mask & 0xFFFF;
    case 0x0a:
        return (s->mask >> 16) & 0xFFFF;
    case 0x10:
    case 0x80:
    {
        uint16_t num = s->ith_v;

        if (num == 4 || num == 5 || num == 15) {
            s->levels &= ~(1u << num);
        }

        calypso_inth_update(s);
        {
            static uint32_t total = 0;
            static uint32_t irq7_count = 0;
            total++;
            if (num == 7) {
                irq7_count++;
                if (irq7_count <= 50 || (irq7_count % 100) == 0)
                    fprintf(stderr, "[INTH] IRQ7 dispatch #%u (total=%u) levels=0x%08x mask=0x%08x\n",
                            irq7_count, total, s->levels, s->mask);
            }
            if (total <= 20 || total == 100 || total == 500 || total == 1000)
                fprintf(stderr, "[INTH] IRQ_NUM=%u (#%u) levels=0x%08x mask=0x%08x\n",
                        num, total, s->levels, s->mask);
        }
        return num;
    }
    case 0x12:
    case 0x82:
    {

        uint16_t num = s->fiq_v;
        if (num == 4 || num == 5 || num == 15) {
            s->levels &= ~(1u << num);
        }
        calypso_inth_update(s);
        static unsigned fiq_log;
        if (fiq_log++ < 30)
            fprintf(stderr, "[INTH] FIQ_NUM=%u read levels=0x%08x mask=0x%08x\n",
                    num, s->levels, s->mask);
        return num;
    }
    case 0x14:
    case 0x84:
        return 0;
    default:
        if (offset >= 0x20 && offset < 0x60) {
            int idx = (offset - 0x20) / 2;
            return s->ilr[idx];
        }
        return 0;
    }
}

static void calypso_inth_write(void *opaque, hwaddr offset, uint64_t value,
                                unsigned size)
{
    CalypsoINTHState *s = CALYPSO_INTH(opaque);

    switch (offset) {

    case 0x00:
    {
        uint32_t old = s->levels;
        s->levels &= (0xFFFF0000u | (uint32_t)(value & 0xFFFF));
        if (old != s->levels) {
            static unsigned _n = 0;
            if (_n++ < 20)
                fprintf(stderr, "[INTH] IT_REG1-ACK val=0x%04x levels 0x%08x -> 0x%08x\n",
                        (unsigned)value, old, s->levels);
        }
        calypso_inth_update(s);
        break;
    }
    case 0x02:
    {
        uint32_t old = s->levels;
        s->levels &= (0x0000FFFFu | ((uint32_t)(value & 0xFFFF) << 16));
        if (old != s->levels) {
            static unsigned _n = 0;
            if (_n++ < 20)
                fprintf(stderr, "[INTH] IT_REG2-ACK val=0x%04x levels 0x%08x -> 0x%08x\n",
                        (unsigned)value, old, s->levels);
        }
        calypso_inth_update(s);
        break;
    }
    case 0x08:
    {
        uint32_t old = s->mask;
        s->mask = (s->mask & 0xFFFF0000) | (value & 0xFFFF);

        static unsigned mask_log;
        if (mask_log++ < 50)
            fprintf(stderr,
                    "[INTH] MASK-W LO val=0x%04x  full 0x%08x → 0x%08x  "
                    "bit6(SIM)=%d bit7(UART)=%d levels=0x%08x\n",
                    (unsigned)value, old, s->mask,
                    !!(s->mask & (1u<<6)), !!(s->mask & (1u<<7)),
                    s->levels);
        calypso_inth_update(s);
        break;
    }
    case 0x0a:
    {
        uint32_t old = s->mask;
        s->mask = (s->mask & 0x0000FFFF) | ((value & 0xFFFF) << 16);
        static unsigned mask_log_hi;
        if (mask_log_hi++ < 50)
            fprintf(stderr,
                    "[INTH] MASK-W HI val=0x%04x  full 0x%08x → 0x%08x\n",
                    (unsigned)value, old, s->mask);
        calypso_inth_update(s);
        break;
    }
    case 0x14:
    case 0x84:
    {

        uint16_t svc = s->ith_v;
        if (svc > 0 || (s->levels & 1)) {

            s->rr_start = (svc + 1) % CALYPSO_INTH_NUM_IRQS;
        }
        calypso_inth_update(s);
        break;
    }
    default:
        if (offset >= 0x20 && offset < 0x60) {
            int idx = (offset - 0x20) / 2;
            s->ilr[idx] = value & 0x1FFF;

            if (idx == 7) {
                s->ilr[7] = (s->ilr[7] & ~0x1F) | (s->ilr[4] & 0x1F);
            }

            if (idx == 18) {
                s->ilr[18] = (s->ilr[18] & ~0x1F) | (s->ilr[4] & 0x1F);
            }
        }
        break;
    }
}

static const MemoryRegionOps calypso_inth_ops = {
    .read = calypso_inth_read,
    .write = calypso_inth_write,
    .endianness = DEVICE_NATIVE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 2 },
    .impl  = { .min_access_size = 1, .max_access_size = 2 },
};

static void calypso_inth_realize(DeviceState *dev, Error **errp)
{
    CalypsoINTHState *s = CALYPSO_INTH(dev);

    g_inth = s;

    memory_region_init_io(&s->iomem, OBJECT(dev), &calypso_inth_ops, s,
                          "calypso-inth", 0x100);
    sysbus_init_mmio(SYS_BUS_DEVICE(dev), &s->iomem);

    sysbus_init_irq(SYS_BUS_DEVICE(dev), &s->parent_irq);
    sysbus_init_irq(SYS_BUS_DEVICE(dev), &s->parent_fiq);

    qdev_init_gpio_in(dev, calypso_inth_set_irq, CALYPSO_INTH_NUM_IRQS);
}

static void calypso_inth_reset(DeviceState *dev)
{
    CalypsoINTHState *s = CALYPSO_INTH(dev);

    s->levels = 0;
    s->mask = 0x00000000;
    s->ith_v = 0;
    s->fiq_v = 0;
    s->irq_in_service = -1;
    s->rr_start = 0;
    memset(s->ilr, 0, sizeof(s->ilr));
}

static void calypso_inth_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    dc->realize = calypso_inth_realize;
    device_class_set_legacy_reset(dc, calypso_inth_reset);
    dc->desc = "Calypso INTH interrupt controller";
}

static const TypeInfo calypso_inth_info = {
    .name          = TYPE_CALYPSO_INTH,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(CalypsoINTHState),
    .class_init    = calypso_inth_class_init,
};

static void calypso_inth_register_types(void)
{
    type_register_static(&calypso_inth_info);
}

type_init(calypso_inth_register_types)
