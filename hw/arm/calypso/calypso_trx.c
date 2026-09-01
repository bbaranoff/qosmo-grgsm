/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "qemu/osdep.h"
#include "qemu/timer.h"
#include "qemu/main-loop.h"
#include "sysemu/runstate.h"
#include "exec/address-spaces.h"
#include "exec/cpu-common.h"
#include "hw/core/cpu.h"
#include "hw/irq.h"
#include "hw/arm/calypso/calypso_api.h"
#include "hw/arm/calypso/calypso_l1.h"
#include "hw/arm/calypso/calypso_trx.h"
#include "hw/arm/calypso/calypso_uart.h"
#include "hw/arm/calypso/calypso_timer.h"
#include "hw/arm/calypso/calypso_sim.h"
#include <pthread.h>
#include <time.h>

extern CalypsoUARTState *g_uart_modem;
extern CalypsoUARTState *g_uart_irda;

#define FRAME_IRQ_PULSE_NS     1000000
#define CPU_KICK_NS            5000000
#define IDLE_PC_LO             0x00823000u
#define IDLE_PC_HI             0x00826000u
#define INTH_MASK_ADDR         0xFFFFFA08u
#define BOOT_POLLS_BEFORE_BOOT 3

typedef struct CalypsoTRX {
    qemu_irq *irqs;
    MemoryRegion api_iomem;
    uint16_t api_ram[CALYPSO_API_WORDS];
    uint8_t dsp_page;
    bool bl_booted;
    unsigned bl_polls;
    MemoryRegion tpu_iomem;
    MemoryRegion tpu_ram_iomem;
    uint16_t tpu_regs[CALYPSO_TPU_SIZE / 2];
    uint16_t tpu_ram[CALYPSO_TPU_RAM_SIZE / 2];
    MemoryRegion tsp_iomem;
    uint16_t tsp_regs[CALYPSO_TSP_SIZE / 2];
    MemoryRegion ulpd_iomem;
    uint16_t ulpd_regs[CALYPSO_ULPD_SIZE / 2];
    uint32_t ulpd_counter;
    MemoryRegion sim_iomem;
    CalypsoSim *sim;
    QEMUTimer *tdma_timer;
    QEMUTimer *frame_irq_timer;
    QEMUTimer *kick_timer;
    uint32_t fn;
    int64_t fn_offset;
    bool fn_synced;
    bool tdma_running;
    uint8_t burst_ring[8];
    unsigned burst_w, burst_r;
    uint16_t burst_cur;
    uint32_t burst_last_fn;
} CalypsoTRX;

static CalypsoTRX *g_trx;
static volatile uint32_t g_wall_fn;
static volatile bool g_wall_running;
static pthread_t g_wall_thread;

uint16_t *calypso_api_ram(void)
{
    return g_trx->api_ram;
}

uint32_t calypso_trx_get_fn(void)
{
    return g_trx ? (uint32_t)((int64_t)g_trx->fn + g_trx->fn_offset) : 0;
}

void calypso_trx_autosync_fn(uint32_t sch_fn)
{
    if (!g_trx || g_trx->fn_synced) {
        return;
    }
    g_trx->fn_offset = (int64_t)sch_fn - (int64_t)g_trx->fn;
    g_trx->fn_synced = true;
    fprintf(stderr, "[trx] horloge FN calee sur le SCH gr-gsm : fn=%u offset=%lld\n",
            sch_fn, (long long)g_trx->fn_offset);
}

static uint64_t api_read(void *opaque, hwaddr off, unsigned size)
{
    CalypsoTRX *s = opaque;
    if (off >= CALYPSO_API_SIZE) {
        return 0;
    }
    const uint16_t *src = &s->api_ram[off / 2];
    uint64_t val = (size == 2) ? src[0] :
                   (size == 4) ? ((uint32_t)src[0] | ((uint32_t)src[1] << 16)) :
                   ((const uint8_t *)src)[off & 1];
    if (size != 2) {
        return val;
    }

    uint16_t rv;
    if (calypso_l1_read_override((uint32_t)off, &rv)) {
        val = rv;
    }
    if (off == API_R_PAGE(0) + RP_D_TASK_D || off == API_R_PAGE(1) + RP_D_TASK_D) {
        s->burst_cur = s->burst_ring[s->burst_r++ & 7u];
        if (val == 0 && calypso_l1_si_valid()) {
            val = ALLC_DSP_TASK;
        }
    }
    if (off == API_R_PAGE(0) + RP_D_BURST_D || off == API_R_PAGE(1) + RP_D_BURST_D) {
        val = (uint16_t)((s->burst_cur + 3) & 3);
    }
    if (off == API_BL_STATUS && !s->bl_booted && ++s->bl_polls > BOOT_POLLS_BEFORE_BOOT) {
        s->api_ram[API_BL_STATUS / 2] = BL_STATUS_BOOT;
        s->api_ram[API_VERSION / 2] = API_VERSION_VALUE;
        s->api_ram[API_VERSION2 / 2] = 0;
        s->bl_booted = true;
        val = BL_STATUS_BOOT;
    }
    return val;
}

static void api_write(void *opaque, hwaddr off, uint64_t value, unsigned size)
{
    CalypsoTRX *s = opaque;
    if (off >= CALYPSO_API_SIZE) {
        return;
    }
    if (size == 2) {
        s->api_ram[off / 2] = (uint16_t)value;
    } else if (size == 4) {
        s->api_ram[off / 2] = (uint16_t)value;
        s->api_ram[off / 2 + 1] = (uint16_t)(value >> 16);
    } else {
        ((uint8_t *)s->api_ram)[off] = (uint8_t)value;
    }

    if (size == 2 && (off == API_W_PAGE(0) + WP_D_BURST_D ||
                      off == API_W_PAGE(1) + WP_D_BURST_D)) {
        uint32_t wfn = calypso_l1s_fn();
        if (wfn != s->burst_last_fn + 1) {
            s->burst_w = s->burst_r = 0;
        }
        s->burst_last_fn = wfn;
        s->burst_ring[s->burst_w++ & 7u] = (uint8_t)(value & 3);
        calypso_l1_burst_written((uint16_t)value);
    }
    if (off == API_NDB + NDB_D_RACH && value != 0 && (size == 2 || size == 4)) {
        calypso_l1_rach_written((uint16_t)value, s->fn);
    }
    if (off == API_NDB + NDB_D_DSP_PAGE && size == 2) {
        s->dsp_page = value & 1;
        calypso_l1_page_written((uint16_t)value);
    }
    if (off == API_BL_STATUS) {
        if (value == 0) {
            s->bl_booted = false;
            s->bl_polls = 0;
        } else if (value == BL_STATUS_READY) {
            s->api_ram[API_VERSION / 2] = API_VERSION_VALUE;
            s->api_ram[API_VERSION2 / 2] = 0;
            uint16_t mask;
            cpu_physical_memory_read(INTH_MASK_ADDR, &mask, 2);
            mask &= ~(1 << CALYPSO_IRQ_API);
            cpu_physical_memory_write(INTH_MASK_ADDR, &mask, 2);
            s->api_ram[API_NDB / 2] = 0;
        }
    }
}

static const MemoryRegionOps api_ops = {
    .read = api_read,
    .write = api_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

static void tpu_done(CalypsoTRX *s)
{
    s->tpu_regs[TPU_CTRL / 2] &= ~TPU_CTRL_EN;
    calypso_tpu_run_scenario(s->tpu_ram, s->fn, s->tpu_regs);
    qemu_irq_raise(s->irqs[CALYPSO_IRQ_API]);
}

static void tdma_start(CalypsoTRX *s);

static uint64_t tpu_read(void *o, hwaddr off, unsigned sz)
{
    CalypsoTRX *s = o;
    if (off == TPU_IT_DSP_PG) {
        return s->dsp_page;
    }
    return (off / 2 < CALYPSO_TPU_SIZE / 2) ? s->tpu_regs[off / 2] : 0;
}

static void tpu_write(void *o, hwaddr off, uint64_t val, unsigned sz)
{
    CalypsoTRX *s = o;
    if (off / 2 < CALYPSO_TPU_SIZE / 2) {
        s->tpu_regs[off / 2] = val;
    }
    if (off == TPU_CTRL && (val & TPU_CTRL_EN)) {
        s->tpu_regs[TPU_CTRL / 2] &= ~(TPU_CTRL_EN | TPU_CTRL_IDLE);
        tpu_done(s);
    }
    if (off == TPU_INT_CTRL && !(val & ICTRL_MCU_FRAME) && !s->tdma_running) {
        tdma_start(s);
    }
    if (off == TPU_IT_DSP_PG) {
        s->dsp_page = val & 1;
    }
}

static const MemoryRegionOps tpu_ops = {
    .read = tpu_read,
    .write = tpu_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

static uint64_t tpu_ram_read(void *o, hwaddr off, unsigned sz)
{
    CalypsoTRX *s = o;
    return (off / 2 < CALYPSO_TPU_RAM_SIZE / 2) ? s->tpu_ram[off / 2] : 0;
}

static void tpu_ram_write(void *o, hwaddr off, uint64_t v, unsigned sz)
{
    CalypsoTRX *s = o;
    if (off / 2 < CALYPSO_TPU_RAM_SIZE / 2) {
        s->tpu_ram[off / 2] = v;
    }
}

static const MemoryRegionOps tpu_ram_ops = {
    .read = tpu_ram_read,
    .write = tpu_ram_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

static uint64_t tsp_read(void *o, hwaddr off, unsigned sz)
{
    CalypsoTRX *s = o;
    if (off == TSP_RX_REG) {
        return 0xFFFF;
    }
    return (off / 2 < CALYPSO_TSP_SIZE / 2) ? s->tsp_regs[off / 2] : 0;
}

static void tsp_write(void *o, hwaddr off, uint64_t v, unsigned sz)
{
    CalypsoTRX *s = o;
    if (off / 2 < CALYPSO_TSP_SIZE / 2) {
        s->tsp_regs[off / 2] = v;
    }
}

static const MemoryRegionOps tsp_ops = {
    .read = tsp_read,
    .write = tsp_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

static uint64_t ulpd_read(void *o, hwaddr off, unsigned sz)
{
    CalypsoTRX *s = o;
    if (off >= 0x20 && off <= 0x40) {
        return 0;
    }
    switch (off) {
    case ULPD_SETUP_CLK13:
        return 0x2003;
    case ULPD_COUNTER_HI:
        s->ulpd_counter += 100;
        return (s->ulpd_counter >> 16) & 0xFFFF;
    case ULPD_COUNTER_LO:
        return s->ulpd_counter & 0xFFFF;
    case ULPD_GAUGING_CTRL:
        return 1;
    case ULPD_GSM_TIMER:
        return s->fn & 0xFFFF;
    default:
        return (off / 2 < CALYPSO_ULPD_SIZE / 2) ? s->ulpd_regs[off / 2] : 0;
    }
}

static void ulpd_write(void *o, hwaddr off, uint64_t v, unsigned sz)
{
    CalypsoTRX *s = o;
    if (off >= 0x20 && off <= 0x40) {
        return;
    }
    if (off / 2 < CALYPSO_ULPD_SIZE / 2) {
        s->ulpd_regs[off / 2] = v;
    }
}

static const MemoryRegionOps ulpd_ops = {
    .read = ulpd_read,
    .write = ulpd_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 2 },
    .impl = { .min_access_size = 1, .max_access_size = 2 },
};

static uint64_t sim_read(void *o, hwaddr off, unsigned sz)
{
    CalypsoTRX *s = o;
    return calypso_sim_reg_read(s->sim, off);
}

static void sim_write(void *o, hwaddr off, uint64_t v, unsigned sz)
{
    CalypsoTRX *s = o;
    calypso_sim_reg_write(s->sim, off, (uint16_t)v);
}

static const MemoryRegionOps sim_ops = {
    .read = sim_read,
    .write = sim_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl = { .min_access_size = 1, .max_access_size = 4 },
};

static void cpu_idle_park(void)
{
    CPUState *cs = first_cpu;
    if (!cs) {
        return;
    }
    uint64_t pc = (cs->cc && cs->cc->get_pc) ? cs->cc->get_pc(cs) : 0;
    if (pc < IDLE_PC_LO || pc >= IDLE_PC_HI) {
        return;
    }
    cs->halted = 1;
    cpu_exit(cs);
}

static void frame_irq_lower(void *o)
{
    CalypsoTRX *s = o;
    qemu_irq_lower(s->irqs[CALYPSO_IRQ_TPU_FRAME]);
    calypso_l1_frame_tick();
    cpu_idle_park();
}

static void *wall_clock_loop(void *arg)
{
    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);
    while (g_wall_running) {
        next.tv_nsec += GSM_TDMA_NS;
        while (next.tv_nsec >= 1000000000L) {
            next.tv_nsec -= 1000000000L;
            next.tv_sec += 1;
        }
        int rc = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
        if (rc != 0 && rc != EINTR) {
            break;
        }
        __atomic_add_fetch(&g_wall_fn, 1, __ATOMIC_RELEASE);
    }
    return NULL;
}

static void tdma_tick(void *opaque)
{
    CalypsoTRX *s = opaque;
    if (!runstate_is_running()) {
        timer_mod_ns(s->tdma_timer, qemu_clock_get_ns(QEMU_CLOCK_REALTIME) + GSM_TDMA_NS);
        return;
    }
    uint32_t wfn = __atomic_load_n(&g_wall_fn, __ATOMIC_ACQUIRE);
    s->fn = (wfn ? wfn : s->fn + 1) % GSM_HYPERFRAME;

    calypso_tpu_sequencer_tick(s->fn);
    if (g_uart_modem) {
        calypso_uart_poll_backend(g_uart_modem);
        calypso_uart_kick_rx(g_uart_modem);
    }
    if (g_uart_irda) {
        calypso_uart_poll_backend(g_uart_irda);
        calypso_uart_kick_rx(g_uart_irda);
    }

    *api_wp(s->dsp_page, WP_D_TASK_RA) = 0;
    *api_wp(s->dsp_page, WP_D_TASK_U) = 0;

    calypso_timer_lost_frame_tick(s->fn);
    qemu_irq_raise(s->irqs[CALYPSO_IRQ_TPU_FRAME]);
    timer_mod_ns(s->frame_irq_timer,
                 qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + FRAME_IRQ_PULSE_NS);

    static int64_t target;
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_REALTIME);
    if (target == 0) {
        target = now;
    }
    target += GSM_TDMA_NS;
    while (target <= now) {
        target += GSM_TDMA_NS;
    }
    timer_mod_ns(s->tdma_timer, target);
}

static void tdma_start(CalypsoTRX *s)
{
    s->tdma_running = true;
    s->fn = 0;
    timer_mod_ns(s->tdma_timer, qemu_clock_get_ns(QEMU_CLOCK_REALTIME) + GSM_TDMA_NS);
}

static void cpu_kick(void *o)
{
    CalypsoTRX *s = o;
    if (first_cpu) {
        cpu_exit(first_cpu);
    }
    qemu_notify_event();
    timer_mod_ns(s->kick_timer, qemu_clock_get_ns(QEMU_CLOCK_REALTIME) + CPU_KICK_NS);
}

static void map_io(MemoryRegion *sysmem, MemoryRegion *mr, const MemoryRegionOps *ops,
                   void *opaque, const char *name, hwaddr base, uint64_t size)
{
    memory_region_init_io(mr, NULL, ops, opaque, name, size);
    memory_region_add_subregion(sysmem, base, mr);
}

void calypso_trx_init(MemoryRegion *sysmem, qemu_irq *irqs)
{
    CalypsoTRX *s = g_new0(CalypsoTRX, 1);
    g_trx = s;
    s->irqs = irqs;

    map_io(sysmem, &s->api_iomem, &api_ops, s, "calypso.dsp_api", CALYPSO_API_BASE,
           CALYPSO_API_SIZE);
    s->api_ram[API_BL_STATUS / 2] = BL_STATUS_READY;
    s->api_ram[API_VERSION / 2] = API_VERSION_VALUE;
    s->bl_booted = true;

    map_io(sysmem, &s->tpu_iomem, &tpu_ops, s, "calypso.tpu", CALYPSO_TPU_BASE,
           CALYPSO_TPU_SIZE);
    map_io(sysmem, &s->tpu_ram_iomem, &tpu_ram_ops, s, "calypso.tpu_ram",
           CALYPSO_TPU_RAM_BASE, CALYPSO_TPU_RAM_SIZE);
    map_io(sysmem, &s->tsp_iomem, &tsp_ops, s, "calypso.tsp", CALYPSO_TSP_BASE,
           CALYPSO_TSP_SIZE);
    map_io(sysmem, &s->ulpd_iomem, &ulpd_ops, s, "calypso.ulpd", CALYPSO_ULPD_BASE,
           CALYPSO_ULPD_SIZE);
    s->sim = calypso_sim_new(s->irqs[CALYPSO_IRQ_SIM]);
    map_io(sysmem, &s->sim_iomem, &sim_ops, s, "calypso.sim", CALYPSO_SIM_BASE,
           CALYPSO_SIM_SIZE);

    s->tdma_timer = timer_new_ns(QEMU_CLOCK_REALTIME, tdma_tick, s);
    s->frame_irq_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, frame_irq_lower, s);
    s->kick_timer = timer_new_ns(QEMU_CLOCK_REALTIME, cpu_kick, s);
    timer_mod_ns(s->kick_timer, qemu_clock_get_ns(QEMU_CLOCK_REALTIME) + CPU_KICK_NS);

    g_wall_running = true;
    pthread_create(&g_wall_thread, NULL, wall_clock_loop, NULL);
    pthread_setname_np(g_wall_thread, "cal-tdma-clock");
}
