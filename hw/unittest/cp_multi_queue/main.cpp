// 实验11：在完整VX_cp_core上验证四个独立Ring的资源竞争和跨资源并行。
#include "vl_simulator.h"
#include "VVX_cp_core_top.h"

#include <array>
#include <cmath>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#ifndef PRIORITY_ARBITRATION
#define PRIORITY_ARBITRATION 1
#endif
#ifndef ARBITRATION_AGING
#define ARBITRATION_AGING 1
#endif

static uint64_t timestamp = 0;
static bool trace_en = false;
double sc_time_stamp() { return timestamp; }
bool sim_trace_enabled() { return trace_en; }
void sim_trace_enable(bool enable) { trace_en = enable; }

#define EXPECT(cond, msg) do {                                             \
    if (!(cond)) {                                                         \
        std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg); \
        std::exit(1);                                                      \
    }                                                                      \
} while (0)

static constexpr int NQ = 4;
static constexpr int CL_BYTES = 64;
static constexpr uint8_t OP_MEM_COPY  = 0x03;
static constexpr uint8_t OP_DCR_WRITE = 0x04;
static constexpr uint8_t OP_LAUNCH    = 0x06;
static constexpr uint8_t OP_EVT_SIG   = 0x08;

static constexpr uint16_t CP_CTRL          = 0x000;
static constexpr uint16_t CP_DEV_CAPS      = 0x008;
static constexpr uint16_t Q_BASE           = 0x100;
static constexpr uint16_t Q_STRIDE         = 0x040;
static constexpr uint16_t Q_RING_BASE_LO   = 0x00;
static constexpr uint16_t Q_RING_BASE_HI   = 0x04;
static constexpr uint16_t Q_CMPL_ADDR_LO   = 0x10;
static constexpr uint16_t Q_CMPL_ADDR_HI   = 0x14;
static constexpr uint16_t Q_RING_SIZE_LOG2 = 0x18;
static constexpr uint16_t Q_CONTROL        = 0x1c;
static constexpr uint16_t Q_TAIL_LO        = 0x20;
static constexpr uint16_t Q_TAIL_HI        = 0x24;

struct Command {
    uint8_t opcode;
    uint64_t arg0;
    uint64_t arg1;
    uint64_t arg2;
};

static int command_size(uint8_t opcode) {
    switch (opcode) {
    case OP_LAUNCH:    return 12;
    case OP_DCR_WRITE:
    case OP_EVT_SIG:   return 20;
    case OP_MEM_COPY:  return 28;
    default:           return -1;
    }
}

static void emit64(uint8_t* dst, size_t offset, uint64_t value) {
    for (int i = 0; i < 8; ++i)
        dst[offset + i] = static_cast<uint8_t>(value >> (8 * i));
}

static void emit_command(uint8_t* dst, size_t offset, const Command& cmd) {
    const int size = command_size(cmd.opcode);
    EXPECT(size > 0, "不支持的多队列命令");
    dst[offset] = cmd.opcode;
    dst[offset + 1] = 0;
    dst[offset + 2] = 0;
    dst[offset + 3] = 0;
    if (size >= 8)  emit64(dst, offset + 4, cmd.arg0);
    if (size >= 20) emit64(dst, offset + 12, cmd.arg1);
    if (size >= 28) emit64(dst, offset + 20, cmd.arg2);
}

struct Options {
    std::string scenario = "same-dma";
    std::string timeline;
    int commands = 4;
    bool quiet = false;
};

static bool starts_with(const char* value, const char* prefix) {
    return std::strncmp(value, prefix, std::strlen(prefix)) == 0;
}

static Options parse_args(int argc, char** argv) {
    Options opt;
    for (int i = 1; i < argc; ++i) {
        if (starts_with(argv[i], "--scenario=")) {
            opt.scenario = argv[i] + std::strlen("--scenario=");
        } else if (starts_with(argv[i], "--timeline=")) {
            opt.timeline = argv[i] + std::strlen("--timeline=");
        } else if (starts_with(argv[i], "--commands=")) {
            opt.commands = std::atoi(argv[i] + std::strlen("--commands="));
            EXPECT(opt.commands > 0 && opt.commands <= 64, "--commands范围必须为1到64");
        } else if (std::strcmp(argv[i], "--quiet") == 0) {
            opt.quiet = true;
        } else {
            std::fprintf(stderr,
                "Usage: %s [--scenario=same-dma|mixed|isolated-dma|isolated-dcr|isolated-event|isolated-kmu] [--commands=N] [--quiet]\n",
                argv[0]);
            std::exit(2);
        }
    }
    return opt;
}

template <size_t MEM_SIZE>
struct ByteMemory {
    uint64_t base;
    std::array<uint8_t, MEM_SIZE> data{};

    explicit ByteMemory(uint64_t base_) : base(base_) {}

    bool contains(uint64_t addr) const {
        return addr >= base && addr < base + MEM_SIZE;
    }

    uint8_t read8(uint64_t addr) const {
        EXPECT(contains(addr), "AXI读地址越界");
        return data[static_cast<size_t>(addr - base)];
    }

    void write8(uint64_t addr, uint8_t value) {
        EXPECT(contains(addr), "AXI写地址越界");
        data[static_cast<size_t>(addr - base)] = value;
    }

    uint64_t read64(uint64_t addr) const {
        uint64_t value = 0;
        for (int i = 0; i < 8; ++i)
            value |= uint64_t(read8(addr + i)) << (8 * i);
        return value;
    }

    void write64(uint64_t addr, uint64_t value) {
        for (int i = 0; i < 8; ++i)
            write8(addr + i, static_cast<uint8_t>(value >> (8 * i)));
    }

    template <typename Wide>
    void read_beat(uint64_t addr, Wide& wide) const {
        for (int word = 0; word < 16; ++word) {
            uint32_t value = 0;
            for (int byte = 0; byte < 4; ++byte)
                value |= uint32_t(read8(addr + word * 4 + byte)) << (8 * byte);
            wide[word] = value;
        }
    }

    template <typename WideData>
    void write_beat(uint64_t addr, const WideData& wide, uint64_t strb) {
        for (int byte = 0; byte < CL_BYTES; ++byte) {
            const bool enabled = (strb >> byte) & 1u;
            if (enabled) {
                const uint8_t value = static_cast<uint8_t>(
                    wide[byte / 4] >> (8 * (byte % 4)));
                write8(addr + byte, value);
            }
        }
    }
};

struct HostAxiModel {
    static constexpr uint64_t BASE = 0x1000;
    ByteMemory<512 * 1024> mem{BASE};
    bool read_active = false;
    uint64_t read_addr = 0;
    uint16_t read_beats = 0;
    uint8_t read_id = 0;
    bool write_active = false;
    uint64_t write_addr = 0;
    uint16_t write_beats = 0;
    uint8_t write_id = 0;
    bool b_pending = false;

    template <typename T>
    void drive(T* top) {
        top->m_arready = !read_active;
        top->m_rvalid = read_active;
        top->m_rid = read_id;
        top->m_rlast = read_active && (read_beats == 1);
        top->m_rresp = 0;
        if (read_active)
            mem.read_beat(read_addr, top->m_rdata);

        top->m_awready = !write_active && !b_pending;
        top->m_wready = write_active && !b_pending;
        top->m_bvalid = b_pending;
        top->m_bid = write_id;
        top->m_bresp = 0;
    }

    template <typename T>
    void update(T* top) {
        if (top->m_arvalid && top->m_arready) {
            read_active = true;
            read_addr = top->m_araddr;
            read_beats = uint16_t(top->m_arlen) + 1;
            read_id = top->m_arid;
        } else if (read_active && top->m_rvalid && top->m_rready) {
            --read_beats;
            read_addr += CL_BYTES;
            if (read_beats == 0)
                read_active = false;
        }
        if (top->m_awvalid && top->m_awready) {
            write_active = true;
            write_addr = top->m_awaddr;
            write_beats = uint16_t(top->m_awlen) + 1;
            write_id = top->m_awid;
        }
        if (write_active && top->m_wvalid && top->m_wready) {
            mem.write_beat(write_addr, top->m_wdata, top->m_wstrb);
            --write_beats;
            write_addr += CL_BYTES;
            if (top->m_wlast || write_beats == 0) {
                write_active = false;
                b_pending = true;
            }
        }
        if (b_pending && top->m_bvalid && top->m_bready)
            b_pending = false;
    }
};

struct DeviceAxiModel {
    static constexpr uint64_t BASE = 0x80000000ull;
    ByteMemory<256 * 1024> mem{BASE};
    bool read_active = false;
    uint64_t read_addr = 0;
    uint16_t read_beats = 0;
    uint8_t read_id = 0;
    bool write_active = false;
    uint64_t write_addr = 0;
    uint16_t write_beats = 0;
    uint8_t write_id = 0;
    bool b_pending = false;

    template <typename T>
    void drive(T* top) {
        top->d_arready = !read_active;
        top->d_rvalid = read_active;
        top->d_rid = read_id;
        top->d_rlast = read_active && (read_beats == 1);
        top->d_rresp = 0;
        if (read_active)
            mem.read_beat(read_addr, top->d_rdata);

        top->d_awready = !write_active && !b_pending;
        top->d_wready = write_active && !b_pending;
        top->d_bvalid = b_pending;
        top->d_bid = write_id;
        top->d_bresp = 0;
    }

    template <typename T>
    void update(T* top) {
        if (top->d_arvalid && top->d_arready) {
            read_active = true;
            read_addr = top->d_araddr;
            read_beats = uint16_t(top->d_arlen) + 1;
            read_id = top->d_arid;
        } else if (read_active && top->d_rvalid && top->d_rready) {
            --read_beats;
            read_addr += CL_BYTES;
            if (read_beats == 0)
                read_active = false;
        }
        if (top->d_awvalid && top->d_awready) {
            write_active = true;
            write_addr = top->d_awaddr;
            write_beats = uint16_t(top->d_awlen) + 1;
            write_id = top->d_awid;
        }
        if (write_active && top->d_wvalid && top->d_wready) {
            mem.write_beat(write_addr, top->d_wdata, top->d_wstrb);
            --write_beats;
            write_addr += CL_BYTES;
            if (top->d_wlast || write_beats == 0) {
                write_active = false;
                b_pending = true;
            }
        }
        if (b_pending && top->d_bvalid && top->d_bready)
            b_pending = false;
    }
};

struct GpuModel {
    int busy_cycles = 0;
    uint64_t dcr_writes = 0;
    uint64_t launches = 0;

    template <typename T>
    void drive(T* top) {
        top->gpu_dcr_req_ready = 1;
        top->gpu_dcr_rsp_valid = 0;
        top->gpu_dcr_rsp_data = 0;
        top->gpu_busy = busy_cycles > 0;
    }

    template <typename T>
    void update(T* top) {
        if (top->gpu_dcr_req_valid && top->gpu_dcr_req_ready
         && top->gpu_dcr_req_rw)
            ++dcr_writes;
        if (top->gpu_start) {
            ++launches;
            busy_cycles = 12;
        } else if (busy_cycles > 0) {
            --busy_cycles;
        }
    }
};

struct Metrics {
    std::FILE* timeline = nullptr;
    uint64_t cycles = 0;
    std::array<uint64_t, NQ> grants{};
    std::array<uint64_t, NQ> retire_count{};
    std::array<uint64_t, NQ> wait_sum{};
    std::array<uint64_t, NQ> max_wait{};
    std::array<int64_t, NQ> bid_start{{-1, -1, -1, -1}};
    std::array<int64_t, NQ> retire_cycle{{-1, -1, -1, -1}};

    template <typename T>
    void sample(T* top) {
        const uint8_t valid = top->dbg_kmu_valid_all | top->dbg_dma_valid_all
                            | top->dbg_dcr_valid_all | top->dbg_event_valid_all;
        const uint8_t grant = top->dbg_kmu_grant_all | top->dbg_dma_grant_all
                            | top->dbg_dcr_grant_all | top->dbg_event_grant_all;
        if (timeline) {
            std::fprintf(timeline,
                "%" PRIu64 ",0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,0x%x,%u,%u,%u,%u\n",
                cycles, unsigned(top->dbg_q_enabled_all),
                unsigned(top->dbg_engine_fsm_all), unsigned(top->dbg_engine_res_all),
                unsigned(top->dbg_kmu_valid_all), unsigned(top->dbg_kmu_grant_all),
                unsigned(top->dbg_dma_valid_all), unsigned(top->dbg_dma_grant_all),
                unsigned(top->dbg_dcr_valid_all), unsigned(top->dbg_dcr_grant_all),
                unsigned(top->dbg_event_valid_all), unsigned(top->dbg_event_grant_all),
                unsigned(top->dbg_retire_evt_all), unsigned(top->dbg_retire_ready_all),
                unsigned(valid), unsigned(top->dbg_launch_done),
                unsigned(top->dbg_dma_done), unsigned(top->dbg_dcr_done),
                unsigned(top->dbg_event_done));
        }
        for (int q = 0; q < NQ; ++q) {
            if ((valid >> q) & 1u) {
                if (bid_start[q] < 0)
                    bid_start[q] = static_cast<int64_t>(cycles);
            } else if (!((grant >> q) & 1u)) {
                bid_start[q] = -1;
            }
            if ((grant >> q) & 1u) {
                EXPECT(bid_start[q] >= 0, "授权前没有有效请求");
                const uint64_t wait = cycles - uint64_t(bid_start[q]);
                wait_sum[q] += wait;
                if (wait > max_wait[q])
                    max_wait[q] = wait;
                ++grants[q];
                bid_start[q] = -1;
            }
            if (((top->dbg_retire_evt_all >> q) & 1u)
             && ((top->dbg_retire_ready_all >> q) & 1u)) {
                ++retire_count[q];
                retire_cycle[q] = static_cast<int64_t>(cycles);
            }
        }
        ++cycles;
    }
};

template <typename T>
static void init_inputs(T* top) {
    top->s_awvalid = 0; top->s_awaddr = 0;
    top->s_wvalid = 0; top->s_wdata = 0; top->s_wstrb = 0;
    top->s_bready = 0; top->s_arvalid = 0; top->s_araddr = 0; top->s_rready = 0;
    top->m_awready = 0; top->m_wready = 0; top->m_bvalid = 0;
    top->m_bid = 0; top->m_bresp = 0; top->m_arready = 0;
    top->m_rvalid = 0; top->m_rid = 0; top->m_rlast = 0; top->m_rresp = 0;
    top->d_awready = 0; top->d_wready = 0; top->d_bvalid = 0;
    top->d_bid = 0; top->d_bresp = 0; top->d_arready = 0;
    top->d_rvalid = 0; top->d_rid = 0; top->d_rlast = 0; top->d_rresp = 0;
    for (int i = 0; i < 16; ++i) {
        top->m_rdata[i] = 0;
        top->d_rdata[i] = 0;
    }
    top->gpu_dcr_req_ready = 1;
    top->gpu_dcr_rsp_valid = 0;
    top->gpu_dcr_rsp_data = 0;
    top->gpu_busy = 0;
}

template <typename T>
static void cycle(vl_simulator<T>& sim, HostAxiModel& host,
                  DeviceAxiModel& device, GpuModel& gpu, uint64_t& tick,
                  Metrics* metrics = nullptr) {
    auto* top = sim.operator->();
    host.drive(top); device.drive(top); gpu.drive(top); top->eval();
    host.drive(top); device.drive(top); gpu.drive(top); top->eval();
    if (metrics) metrics->sample(top);
    host.update(top); device.update(top); gpu.update(top);
    tick = sim.step(tick, 2);
    host.drive(top); device.drive(top); gpu.drive(top); top->eval();
}

template <typename T>
static void axil_write(vl_simulator<T>& sim, HostAxiModel& host,
                       DeviceAxiModel& device, GpuModel& gpu, uint64_t& tick,
                       uint16_t addr, uint32_t value, Metrics* metrics = nullptr) {
    sim->s_awvalid = 1; sim->s_awaddr = addr;
    sim->s_wvalid = 1; sim->s_wdata = value; sim->s_wstrb = 0xf;
    sim->s_bready = 1;
    bool aw_done = false, w_done = false;
    for (int guard = 0; guard < 64; ++guard) {
        cycle(sim, host, device, gpu, tick, metrics);
        if (!aw_done && sim->s_awready) { aw_done = true; sim->s_awvalid = 0; }
        if (!w_done && sim->s_wready) { w_done = true; sim->s_wvalid = 0; }
        if (aw_done && w_done && sim->s_bvalid) { sim->s_bready = 0; return; }
    }
    EXPECT(false, "AXI-Lite写超时");
}

template <typename T>
static uint32_t axil_read(vl_simulator<T>& sim, HostAxiModel& host,
                          DeviceAxiModel& device, GpuModel& gpu, uint64_t& tick,
                          uint16_t addr) {
    sim->s_arvalid = 1; sim->s_araddr = addr; sim->s_rready = 1;
    bool ar_done = false;
    for (int guard = 0; guard < 64; ++guard) {
        cycle(sim, host, device, gpu, tick);
        if (!ar_done && sim->s_arready) { ar_done = true; sim->s_arvalid = 0; }
        if (sim->s_rvalid) {
            const uint32_t value = sim->s_rdata;
            sim->s_rready = 0;
            return value;
        }
    }
    EXPECT(false, "AXI-Lite读超时");
    return 0;
}

static constexpr uint64_t ring_addr(int q) {
    return HostAxiModel::BASE + uint64_t(q) * 0x10000ull;
}

static constexpr uint64_t completion_addr(int q) {
    return HostAxiModel::BASE + 0x40000ull + uint64_t(q) * CL_BYTES;
}

static uint64_t seed_ring(HostAxiModel& host, int q,
                          const std::vector<Command>& commands) {
    size_t offset = 0;
    for (const auto& cmd : commands) {
        const size_t size = static_cast<size_t>(command_size(cmd.opcode));
        const size_t line_offset = offset % CL_BYTES;
        if (line_offset + size > CL_BYTES)
            offset += CL_BYTES - line_offset;
        std::array<uint8_t, 32> encoded{};
        emit_command(encoded.data(), 0, cmd);
        for (size_t i = 0; i < size; ++i)
            host.mem.write8(ring_addr(q) + offset + i, encoded[i]);
        offset += size;
    }
    return offset;
}

struct TestPlan {
    std::array<bool, NQ> active{};
    std::array<uint8_t, NQ> priority{{0, 1, 2, 3}};
    std::array<std::vector<Command>, NQ> commands;
    uint64_t expected_dcr_writes = 0;
    uint64_t expected_launches = 0;
    std::vector<std::pair<uint64_t, uint64_t>> dma_checks;
    std::vector<std::pair<uint64_t, uint64_t>> event_checks;
};

static void append_dma(TestPlan& plan, DeviceAxiModel& device, int q, int index,
                       uint64_t bytes) {
    const uint64_t src = DeviceAxiModel::BASE + uint64_t(q) * 0x4000ull
                       + uint64_t(index) * 0x400ull;
    const uint64_t dst = DeviceAxiModel::BASE + 0x10000ull
                       + uint64_t(q) * 0x4000ull + uint64_t(index) * 0x400ull;
    for (uint64_t i = 0; i < bytes; ++i)
        device.mem.write8(src + i, uint8_t((q * 37 + index * 11 + i) & 0xff));
    plan.commands[q].push_back({OP_MEM_COPY, dst, src, bytes});
    for (uint64_t i = 0; i < bytes; ++i)
        plan.dma_checks.emplace_back(dst + i, src + i);
}

static TestPlan make_plan(const Options& opt, DeviceAxiModel& device) {
    TestPlan plan;
    if (opt.scenario == "same-dma") {
        for (int q = 0; q < NQ; ++q) {
            plan.active[q] = true;
            for (int c = 0; c < opt.commands; ++c)
                append_dma(plan, device, q, c, 64);
        }
    } else {
        const bool mixed = opt.scenario == "mixed";
        const bool dma = mixed || opt.scenario == "isolated-dma";
        const bool dcr = mixed || opt.scenario == "isolated-dcr";
        const bool event = mixed || opt.scenario == "isolated-event";
        const bool kmu = mixed || opt.scenario == "isolated-kmu";
        EXPECT(dma || dcr || event || kmu, "未知实验11场景");
        if (dma) {
            plan.active[0] = true;
            append_dma(plan, device, 0, 0, 512);
        }
        if (dcr) {
            plan.active[1] = true;
            plan.commands[1].push_back({OP_DCR_WRITE, 0x321, 0xa5a55a5a, 0});
            ++plan.expected_dcr_writes;
        }
        if (event) {
            plan.active[2] = true;
            const uint64_t addr = DeviceAxiModel::BASE + 0xf000;
            const uint64_t value = 0x1122334455667788ull;
            plan.commands[2].push_back({OP_EVT_SIG, addr, value, 0});
            plan.event_checks.emplace_back(addr, value);
        }
        if (kmu) {
            plan.active[3] = true;
            plan.commands[3].push_back({OP_LAUNCH, 0, 0, 0});
            ++plan.expected_launches;
        }
    }
    return plan;
}

static const char* mode_name() {
    if (!PRIORITY_ARBITRATION) return "round_robin";
    return ARBITRATION_AGING ? "priority_aging" : "strict_priority";
}

static double jain_index(const std::array<uint64_t, NQ>& values) {
    double sum = 0.0, squares = 0.0;
    for (auto value : values) {
        sum += double(value);
        squares += double(value) * double(value);
    }
    return squares ? (sum * sum) / (NQ * squares) : 0.0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const Options opt = parse_args(argc, argv);
    vl_simulator<VVX_cp_core_top> sim;
    HostAxiModel host;
    DeviceAxiModel device;
    GpuModel gpu;
    Metrics metrics;
    uint64_t tick = 0;

    init_inputs(sim.operator->());
    tick = sim.reset(tick);
    if (!opt.timeline.empty()) {
        metrics.timeline = std::fopen(opt.timeline.c_str(), "w");
        EXPECT(metrics.timeline != nullptr, "无法创建多队列波形CSV");
        std::fprintf(metrics.timeline,
            "cycle,q_enabled,engine_fsm,engine_res,kmu_bid,kmu_grant,dma_bid,dma_grant,"
            "dcr_bid,dcr_grant,event_bid,event_grant,retire,retire_ready,any_bid,"
            "launch_done,dma_done,dcr_done,event_done\n");
    }
    const uint32_t caps = axil_read(sim, host, device, gpu, tick, CP_DEV_CAPS);
    EXPECT((caps & 0xffu) == NQ, "DEV_CAPS未报告四队列");

    TestPlan plan = make_plan(opt, device);
    std::array<uint64_t, NQ> tails{};
    for (int q = 0; q < NQ; ++q) {
        if (!plan.active[q])
            continue;
        EXPECT(!plan.commands[q].empty(), "活动队列没有命令");
        tails[q] = seed_ring(host, q, plan.commands[q]);
        host.mem.write64(completion_addr(q), UINT64_MAX);
        const uint16_t base = Q_BASE + q * Q_STRIDE;
        axil_write(sim, host, device, gpu, tick, base + Q_RING_BASE_LO,
                   uint32_t(ring_addr(q)));
        axil_write(sim, host, device, gpu, tick, base + Q_RING_BASE_HI,
                   uint32_t(ring_addr(q) >> 32));
        axil_write(sim, host, device, gpu, tick, base + Q_CMPL_ADDR_LO,
                   uint32_t(completion_addr(q)));
        axil_write(sim, host, device, gpu, tick, base + Q_CMPL_ADDR_HI,
                   uint32_t(completion_addr(q) >> 32));
        axil_write(sim, host, device, gpu, tick, base + Q_RING_SIZE_LOG2, 16);
        axil_write(sim, host, device, gpu, tick, base + Q_CONTROL,
                   1u | (uint32_t(plan.priority[q]) << 2));
        axil_write(sim, host, device, gpu, tick, base + Q_TAIL_LO,
                   uint32_t(tails[q]));
        axil_write(sim, host, device, gpu, tick, base + Q_TAIL_HI,
                   uint32_t(tails[q] >> 32));
    }

    // 所有Ring和Tail就绪后再统一开门，避免软件配置顺序伪造队列优先级。
    axil_write(sim, host, device, gpu, tick, CP_CTRL, 1, &metrics);
    uint64_t expected_total = 0;
    for (int q = 0; q < NQ; ++q)
        expected_total += plan.commands[q].size();

    bool complete = false;
    for (int guard = 0; guard < 20000 && !complete; ++guard) {
        cycle(sim, host, device, gpu, tick, &metrics);
        complete = true;
        for (int q = 0; q < NQ; ++q) {
            if (!plan.active[q])
                continue;
            const uint64_t expected_seq = plan.commands[q].size() - 1;
            complete &= host.mem.read64(completion_addr(q)) == expected_seq;
            complete &= metrics.retire_count[q] == plan.commands[q].size();
        }
    }
    EXPECT(complete, "四队列完成写回超时");

    uint64_t retired_total = 0, grant_total = 0;
    for (int q = 0; q < NQ; ++q) {
        retired_total += metrics.retire_count[q];
        grant_total += metrics.grants[q];
        if (plan.active[q]) {
            EXPECT(metrics.retire_count[q] == plan.commands[q].size(),
                   "队列存在丢失或重复退役");
            EXPECT(metrics.grants[q] == plan.commands[q].size(),
                   "资源授权数与命令数不一致");
            EXPECT(host.mem.read64(completion_addr(q)) == plan.commands[q].size() - 1,
                   "完成序号错误");
        }
    }
    EXPECT(retired_total == expected_total, "总退役数错误");
    EXPECT(grant_total == expected_total, "总授权数错误");
    EXPECT(gpu.dcr_writes == plan.expected_dcr_writes, "DCR写次数错误");
    EXPECT(gpu.launches == plan.expected_launches, "Launch次数错误");
    for (const auto& check : plan.dma_checks)
        EXPECT(device.mem.read8(check.first) == device.mem.read8(check.second),
               "DMA拷贝内容错误");
    for (const auto& check : plan.event_checks)
        EXPECT(device.mem.read64(check.first) == check.second, "EVENT_SIGNAL写值错误");

    for (int q = 0; q < NQ; ++q) {
        if (!plan.active[q])
            continue;
        const double average_wait = metrics.grants[q]
            ? double(metrics.wait_sum[q]) / double(metrics.grants[q]) : 0.0;
        std::printf(
            "MQ_QUEUE scenario=%s mode=%s queue=%d priority=%u commands=%zu "
            "grants=%" PRIu64 " average_wait=%.3f max_wait=%" PRIu64
            " retire_cycle=%" PRId64 " final_seqnum=%" PRIu64 "\n",
            opt.scenario.c_str(), mode_name(), q, plan.priority[q],
            plan.commands[q].size(), metrics.grants[q], average_wait,
            metrics.max_wait[q], metrics.retire_cycle[q],
            host.mem.read64(completion_addr(q)));
    }
    const double fairness = opt.scenario == "same-dma"
        ? jain_index(metrics.grants) : 1.0;
    EXPECT(opt.scenario != "same-dma" || fairness > 0.999,
           "同资源竞争出现授权不公平或命令丢失");
    if (!opt.quiet)
        std::fprintf(stderr, "[verify] scenario=%s mode=%s queues=4 commands=%" PRIu64
                             " cycles=%" PRIu64 "\n",
                     opt.scenario.c_str(), mode_name(), expected_total, metrics.cycles);
    std::printf(
        "MQ_RESULT scenario=%s mode=%s active_queues=%u total_commands=%" PRIu64
        " total_cycles=%" PRIu64 " fairness=%.6f dropped=0 duplicate=0 "
        "dma_ok=1 event_ok=1 status=PASS\n",
        opt.scenario.c_str(), mode_name(),
        unsigned(plan.active[0]) + unsigned(plan.active[1])
          + unsigned(plan.active[2]) + unsigned(plan.active[3]),
        expected_total, metrics.cycles, fairness);
    if (metrics.timeline)
        std::fclose(metrics.timeline);
    return 0;
}
