// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

// ============================================================================
// Verilator integration/performance test for VX_cp_core.
//
// Wires the three CP interfaces against synthetic models:
//   - AXI-Lite slave host: drives W/AW + AR transactions for control.
//   - AXI4 master upstream: 16 KiB byte-addressed memory model.
//   - gpu_if: minimal DCR read/write and launch/busy model.
//
// The default invocation runs one DCR_WRITE command as a smoke test. Experiment
// 2 uses --workload/--commands to build compact command rings and collect
// performance counters from debug-only taps in VX_cp_core_top.
// ============================================================================

#include "vl_simulator.h"
#include "VVX_cp_core_top.h"

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#ifndef TRACE_START_TIME
#define TRACE_START_TIME 0ull
#endif
#ifndef TRACE_STOP_TIME
#define TRACE_STOP_TIME -1ull
#endif

static uint64_t timestamp = 0;
static bool     trace_en  = false;
double sc_time_stamp() { return timestamp; }
bool   sim_trace_enabled() { return trace_en; }
void   sim_trace_enable(bool e) { trace_en = e; }

#define EXPECT(cond, msg) do { \
    if (!(cond)) { \
        std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg); \
        std::exit(1); \
    } \
} while (0)

static constexpr int CL_BYTES = 64;
static constexpr int F_PROFILE_BIT = 0;

static constexpr uint8_t OP_NOP        = 0x00;
static constexpr uint8_t OP_MEM_WRITE  = 0x01;
static constexpr uint8_t OP_MEM_READ   = 0x02;
static constexpr uint8_t OP_MEM_COPY   = 0x03;
static constexpr uint8_t OP_DCR_WRITE  = 0x04;
static constexpr uint8_t OP_DCR_READ   = 0x05;
static constexpr uint8_t OP_LAUNCH     = 0x06;
static constexpr uint8_t OP_FENCE      = 0x07;
static constexpr uint8_t OP_EVT_SIG    = 0x08;
static constexpr uint8_t OP_EVT_WAIT   = 0x09;

static constexpr uint32_t DCR_ADDR = 0x123;
static constexpr uint32_t DCR_DATA = 0xDEADBEEF;

enum EngineState : uint8_t {
    ENG_IDLE = 0,
    ENG_DECODE = 1,
    ENG_BID = 2,
    ENG_WAIT_DONE = 3,
    ENG_RETIRE = 4
};

enum FetchState : uint8_t {
    FETCH_IDLE = 0,
    FETCH_ISSUE_AR = 1,
    FETCH_WAIT_R = 2,
    FETCH_EMIT = 3
};

enum Resource : uint8_t {
    RES_KMU = 0,
    RES_DMA = 1,
    RES_DCR = 2,
    RES_EVT = 3
};

static void emit64(uint8_t* bytes, size_t off, uint64_t value) {
    for (int i = 0; i < 8; ++i)
        bytes[off + i] = static_cast<uint8_t>(value >> (8 * i));
}

static int cmd_base_size(uint8_t opcode) {
    switch (opcode) {
    case OP_NOP:        return 4;
    case OP_LAUNCH:     return 12;
    case OP_FENCE:      return 8;
    case OP_DCR_WRITE:
    case OP_DCR_READ:
    case OP_EVT_SIG:    return 20;
    case OP_MEM_WRITE:
    case OP_MEM_READ:
    case OP_MEM_COPY:
    case OP_EVT_WAIT:   return 28;
    default:            return -1;
    }
}

struct RingCmd {
    uint8_t  opcode = 0;
    uint8_t  flags = 0;
    uint64_t arg0 = 0;
    uint64_t arg1 = 0;
    uint64_t arg2 = 0;
    uint64_t profile_slot = 0;
};

static int cmd_size(const RingCmd& cmd) {
    int base = cmd_base_size(cmd.opcode);
    EXPECT(base > 0, "unsupported command opcode");
    return base + ((cmd.flags & (1u << F_PROFILE_BIT)) ? 8 : 0);
}

static void emit_cmd(uint8_t* bytes, size_t off, const RingCmd& cmd) {
    int base = cmd_base_size(cmd.opcode);
    EXPECT(base > 0, "unsupported command opcode");
    bytes[off + 0] = cmd.opcode;
    bytes[off + 1] = cmd.flags;
    bytes[off + 2] = 0;
    bytes[off + 3] = 0;
    if (base >= 8)
        emit64(bytes, off + 4, cmd.arg0);
    if (base >= 20)
        emit64(bytes, off + 12, cmd.arg1);
    if (base >= 28)
        emit64(bytes, off + 20, cmd.arg2);
    if (cmd.flags & (1u << F_PROFILE_BIT))
        emit64(bytes, off + static_cast<size_t>(base), cmd.profile_slot);
}

struct Options {
    std::string workload = "B1";
    int units = 1;
    bool profile = false;
    bool quiet = false;
};

static bool starts_with(const char* s, const char* prefix) {
    return std::strncmp(s, prefix, std::strlen(prefix)) == 0;
}

static int parse_positive_int(const char* s, const char* opt_name) {
    char* end = nullptr;
    long v = std::strtol(s, &end, 10);
    if (!end || *end != '\0' || v <= 0 || v > 1000000) {
        std::fprintf(stderr, "Invalid %s: %s\n", opt_name, s);
        std::exit(2);
    }
    return static_cast<int>(v);
}

static void usage(const char* argv0) {
    std::printf(
        "Usage: %s [--workload=B1|B2|B7|B8|B9] [--commands=N] [--profile=0|1] [--quiet]\n"
        "  B1: DCR_WRITE x N\n"
        "  B2: DCR_READ x N\n"
        "  B7: LAUNCH x N\n"
        "  B8: N groups of DCR_WRITE x 18 + LAUNCH\n"
        "  B9: N groups of DCR_WRITE + DCR_READ + LAUNCH\n",
        argv0);
}

static Options parse_args(int argc, char** argv) {
    Options opt;
    for (int i = 1; i < argc; ++i) {
        if (starts_with(argv[i], "--workload=")) {
            opt.workload = argv[i] + std::strlen("--workload=");
        } else if (starts_with(argv[i], "--commands=")) {
            opt.units = parse_positive_int(argv[i] + std::strlen("--commands="), "--commands");
        } else if (starts_with(argv[i], "--profile=")) {
            const char* v = argv[i] + std::strlen("--profile=");
            if (std::strcmp(v, "0") == 0) {
                opt.profile = false;
            } else if (std::strcmp(v, "1") == 0) {
                opt.profile = true;
            } else {
                std::fprintf(stderr, "Invalid --profile: %s\n", v);
                std::exit(2);
            }
        } else if (std::strcmp(argv[i], "--quiet") == 0) {
            opt.quiet = true;
        } else if (std::strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            std::exit(0);
        } else {
            std::fprintf(stderr, "Unknown option: %s\n", argv[i]);
            usage(argv[0]);
            std::exit(2);
        }
    }
    return opt;
}

struct Workload {
    std::string id;
    int requested_units = 0;
    std::vector<RingCmd> cmds;
    uint64_t expected_dcr_writes = 0;
    uint64_t expected_dcr_reads = 0;
    uint64_t expected_launches = 0;
};

static RingCmd make_cmd(uint8_t opcode, uint64_t arg0, uint64_t arg1,
                        uint64_t arg2, bool profile, uint64_t seq) {
    RingCmd cmd;
    cmd.opcode = opcode;
    cmd.flags = profile ? static_cast<uint8_t>(1u << F_PROFILE_BIT) : 0;
    cmd.arg0 = arg0;
    cmd.arg1 = arg1;
    cmd.arg2 = arg2;
    cmd.profile_slot = 0xC000000000000000ull | seq;
    return cmd;
}

static void append_dcr_write(Workload& wl, bool profile) {
    uint64_t seq = wl.cmds.size();
    wl.cmds.push_back(make_cmd(OP_DCR_WRITE, DCR_ADDR + seq,
                               DCR_DATA ^ static_cast<uint32_t>(seq), 0,
                               profile, seq));
    ++wl.expected_dcr_writes;
}

static void append_dcr_read(Workload& wl, bool profile) {
    uint64_t seq = wl.cmds.size();
    wl.cmds.push_back(make_cmd(OP_DCR_READ, DCR_ADDR + seq, 0, 0,
                               profile, seq));
    ++wl.expected_dcr_reads;
}

static void append_launch(Workload& wl, bool profile) {
    uint64_t seq = wl.cmds.size();
    wl.cmds.push_back(make_cmd(OP_LAUNCH, seq, 0, 0, profile, seq));
    ++wl.expected_launches;
}

static Workload make_workload(const Options& opt) {
    Workload wl;
    wl.id = opt.workload;
    wl.requested_units = opt.units;

    if (opt.workload == "B1") {
        for (int i = 0; i < opt.units; ++i)
            append_dcr_write(wl, opt.profile);
    } else if (opt.workload == "B2") {
        for (int i = 0; i < opt.units; ++i)
            append_dcr_read(wl, opt.profile);
    } else if (opt.workload == "B7") {
        for (int i = 0; i < opt.units; ++i)
            append_launch(wl, opt.profile);
    } else if (opt.workload == "B8") {
        for (int g = 0; g < opt.units; ++g) {
            for (int i = 0; i < 18; ++i)
                append_dcr_write(wl, opt.profile);
            append_launch(wl, opt.profile);
        }
    } else if (opt.workload == "B9") {
        for (int g = 0; g < opt.units; ++g) {
            append_dcr_write(wl, opt.profile);
            append_dcr_read(wl, opt.profile);
            append_launch(wl, opt.profile);
        }
    } else {
        std::fprintf(stderr, "Unsupported cp_core workload: %s\n",
                     opt.workload.c_str());
        std::exit(2);
    }

    EXPECT(!wl.cmds.empty(), "workload produced no commands");
    return wl;
}

// ============================================================================
// Synthetic AXI4 slave (host-memory model).
// ============================================================================
struct AxiSlave {
    static constexpr uint64_t MEM_BASE = 0x1000;
    static constexpr int      MEM_SIZE = 16 * 1024;
    uint8_t mem[MEM_SIZE] = {0};

    bool         r_inflight = false;
    uint64_t     r_addr     = 0;
    uint8_t      r_id       = 0;

    bool         aw_taken   = false;
    uint64_t     aw_addr    = 0;
    uint8_t      aw_id      = 0;
    bool         b_pending  = false;
    uint8_t      b_id       = 0;

    void mem_write_cl(uint64_t addr, const uint8_t* src) {
        for (int i = 0; i < CL_BYTES; ++i) {
            int64_t a = static_cast<int64_t>(addr) - static_cast<int64_t>(MEM_BASE) + i;
            if (a >= 0 && a < MEM_SIZE) mem[a] = src[i];
        }
    }
    void mem_read_cl(uint64_t addr, uint32_t* dst) const {
        for (int w = 0; w < 16; ++w) {
            uint32_t v = 0;
            for (int b = 0; b < 4; ++b) {
                int64_t a = static_cast<int64_t>(addr) - static_cast<int64_t>(MEM_BASE) + w * 4 + b;
                if (a >= 0 && a < MEM_SIZE) v |= static_cast<uint32_t>(mem[a]) << (8 * b);
            }
            dst[w] = v;
        }
    }
    uint64_t mem_read64(uint64_t addr) const {
        uint64_t v = 0;
        for (int i = 0; i < 8; ++i) {
            int64_t a = static_cast<int64_t>(addr) - static_cast<int64_t>(MEM_BASE) + i;
            if (a >= 0 && a < MEM_SIZE) v |= static_cast<uint64_t>(mem[a]) << (8 * i);
        }
        return v;
    }
    void mem_write64(uint64_t addr, uint64_t value) {
        for (int i = 0; i < 8; ++i) {
            int64_t a = static_cast<int64_t>(addr) - static_cast<int64_t>(MEM_BASE) + i;
            if (a >= 0 && a < MEM_SIZE) mem[a] = static_cast<uint8_t>(value >> (8 * i));
        }
    }

    template <typename T>
    void comb_drive(T* top) {
        top->m_arready = !r_inflight;
        top->m_rvalid = r_inflight;
        top->m_rid    = r_id;
        top->m_rlast  = 1;
        top->m_rresp  = 0;
        if (r_inflight) mem_read_cl(r_addr, top->m_rdata);

        top->m_awready = !aw_taken;
        top->m_wready  = aw_taken && !b_pending;
        top->m_bvalid  = b_pending;
        top->m_bid     = b_id;
        top->m_bresp   = 0;
    }
    template <typename T>
    void posedge_update(T* top) {
        if (top->m_arvalid && top->m_arready) {
            r_inflight = true;
            r_addr = top->m_araddr;
            r_id = top->m_arid;
        } else if (r_inflight && top->m_rvalid && top->m_rready) {
            r_inflight = false;
        }
        if (top->m_awvalid && top->m_awready) {
            aw_taken = true;
            aw_addr = top->m_awaddr;
            aw_id = top->m_awid;
        }
        if (aw_taken && top->m_wvalid && top->m_wready) {
            uint64_t v = (static_cast<uint64_t>(top->m_wdata[1]) << 32) | top->m_wdata[0];
            mem_write64(aw_addr, v);
            aw_taken = false;
            b_pending = true;
            b_id = aw_id;
        }
        if (b_pending && top->m_bvalid && top->m_bready)
            b_pending = false;
    }
};

static constexpr uint64_t RING_BASE = AxiSlave::MEM_BASE;
static constexpr uint64_t CMPL_ADDR = AxiSlave::MEM_BASE + 0x3000;
static constexpr size_t   RING_BYTES = 4 * 1024;

static uint64_t seed_ring(AxiSlave& slave, const Workload& wl) {
    std::vector<uint8_t> ring(RING_BYTES, 0);
    size_t off = 0;
    for (const auto& cmd : wl.cmds) {
        int sz = cmd_size(cmd);
        size_t line_off = off % CL_BYTES;
        if (line_off + static_cast<size_t>(sz) > CL_BYTES)
            off += CL_BYTES - line_off;
        EXPECT(off + static_cast<size_t>(sz) <= ring.size(), "ring image overflow");
        emit_cmd(ring.data(), off, cmd);
        off += sz;
    }

    size_t write_bytes = ((off + CL_BYTES - 1) / CL_BYTES) * CL_BYTES;
    for (size_t a = 0; a < write_bytes; a += CL_BYTES)
        slave.mem_write_cl(RING_BASE + a, ring.data() + a);
    return off;
}

// ============================================================================
// Synthetic gpu_if model.
// ============================================================================
struct GpuModel {
    int busy_cnt = 0;
    int dcr_rsp_count = 0;
    uint32_t dcr_rsp_data = 0;
    uint64_t dcr_writes = 0;
    uint64_t dcr_reads = 0;
    uint64_t launches = 0;
    uint32_t last_dcr_addr = 0;
    uint32_t last_dcr_data = 0;

    template <typename T>
    void comb_drive(T* top) {
        top->gpu_dcr_req_ready = 1;
        top->gpu_dcr_rsp_valid = (dcr_rsp_count > 0);
        top->gpu_dcr_rsp_data  = dcr_rsp_data;
        top->gpu_busy = (busy_cnt > 0);
    }
    template <typename T>
    void posedge_update(T* top) {
        if (top->gpu_dcr_req_valid && top->gpu_dcr_req_ready) {
            last_dcr_addr = top->gpu_dcr_req_addr;
            last_dcr_data = top->gpu_dcr_req_data;
            if (top->gpu_dcr_req_rw) {
                ++dcr_writes;
            } else {
                ++dcr_reads;
                dcr_rsp_data = 0x600D0000u | (top->gpu_dcr_req_addr & 0xffffu);
                dcr_rsp_count = 3;
            }
        }
        if (top->gpu_start) {
            ++launches;
            busy_cnt = 4;
        } else if (busy_cnt > 0) {
            --busy_cnt;
        }
        if (dcr_rsp_count > 0)
            --dcr_rsp_count;
    }
};

struct PerfCounters {
    bool enabled = false;
    uint64_t total_cycles = 0;
    uint64_t submitted_commands = 0;
    uint64_t retired_commands = 0;
    uint64_t idle_cycles = 0;
    uint64_t decode_cycles = 0;
    uint64_t bid_cycles = 0;
    uint64_t wait_done_cycles = 0;
    uint64_t retire_cycles = 0;
    uint64_t kmu_wait_cycles = 0;
    uint64_t dma_wait_cycles = 0;
    uint64_t dcr_wait_cycles = 0;
    uint64_t event_wait_cycles = 0;
    uint64_t fetch_cache_lines = 0;
    uint64_t fetch_wait_cycles = 0;
    uint64_t completion_stall_cycles = 0;
    uint64_t arb_wait_cycles = 0;
    uint64_t queue_latency_cycles = 0;
    uint64_t execution_latency_cycles = 0;
    uint64_t total_latency_cycles = 0;
    uint64_t latency_samples = 0;

    std::vector<uint64_t> submit_cycles;
    std::vector<uint64_t> start_cycles;
    size_t submit_rd = 0;
    size_t start_rd = 0;
    int64_t bid_start_cycle = -1;

    template <typename T>
    void sample(T* top) {
        if (!enabled)
            return;

        const uint64_t cyc = total_cycles;
        ++total_cycles;

        switch (top->dbg_engine_fsm) {
        case ENG_IDLE:      ++idle_cycles; break;
        case ENG_DECODE:    ++decode_cycles; break;
        case ENG_BID:       ++bid_cycles; break;
        case ENG_WAIT_DONE: ++wait_done_cycles; break;
        case ENG_RETIRE:    ++retire_cycles; break;
        default: break;
        }

        if (top->dbg_engine_fsm == ENG_WAIT_DONE) {
            switch (top->dbg_engine_res) {
            case RES_KMU: ++kmu_wait_cycles; break;
            case RES_DMA: ++dma_wait_cycles; break;
            case RES_DCR: ++dcr_wait_cycles; break;
            case RES_EVT: ++event_wait_cycles; break;
            default: break;
            }
        }

        if (top->dbg_fetch_state == FETCH_ISSUE_AR ||
            top->dbg_fetch_state == FETCH_WAIT_R)
            ++fetch_wait_cycles;

        if (top->m_arvalid && top->m_arready)
            ++fetch_cache_lines;

        if (top->dbg_engine_fsm == ENG_RETIRE && !top->dbg_retire_ready)
            ++completion_stall_cycles;

        if (top->dbg_cmd_valid && top->dbg_cmd_ready) {
            ++submitted_commands;
            submit_cycles.push_back(cyc);
        }

        bool bid_grant =
            (top->dbg_kmu_valid && top->dbg_kmu_grant) ||
            (top->dbg_dma_valid && top->dbg_dma_grant) ||
            (top->dbg_dcr_valid && top->dbg_dcr_grant) ||
            (top->dbg_event_valid && top->dbg_event_grant);

        if (top->dbg_engine_fsm == ENG_BID) {
            if (bid_start_cycle < 0)
                bid_start_cycle = static_cast<int64_t>(cyc);
            if (bid_grant) {
                arb_wait_cycles += cyc - static_cast<uint64_t>(bid_start_cycle);
                if (submit_rd < submit_cycles.size()) {
                    queue_latency_cycles += cyc - submit_cycles[submit_rd];
                    start_cycles.push_back(cyc);
                }
                bid_start_cycle = -1;
            }
        } else {
            bid_start_cycle = -1;
        }

        if (top->dbg_retire_evt && top->dbg_retire_ready) {
            ++retired_commands;
            if (submit_rd < submit_cycles.size()) {
                total_latency_cycles += cyc - submit_cycles[submit_rd];
                ++submit_rd;
            }
            if (start_rd < start_cycles.size()) {
                execution_latency_cycles += cyc - start_cycles[start_rd];
                ++start_rd;
            }
            ++latency_samples;
        }
    }
};

template <typename T>
static void drive_device_axi_idle(T* top) {
    top->d_awready = 0;
    top->d_wready = 0;
    top->d_bvalid = 0;
    top->d_bid = 0;
    top->d_bresp = 0;
    top->d_arready = 0;
    top->d_rvalid = 0;
    top->d_rid = 0;
    top->d_rlast = 0;
    top->d_rresp = 0;
    for (int i = 0; i < 16; ++i)
        top->d_rdata[i] = 0;
}

template <typename T>
static void init_inputs(T* top) {
    top->s_awvalid = 0;
    top->s_awaddr = 0;
    top->s_wvalid = 0;
    top->s_wdata = 0;
    top->s_wstrb = 0;
    top->s_bready = 0;
    top->s_arvalid = 0;
    top->s_araddr = 0;
    top->s_rready = 0;

    top->m_awready = 0;
    top->m_wready = 0;
    top->m_bvalid = 0;
    top->m_bid = 0;
    top->m_bresp = 0;
    top->m_arready = 0;
    top->m_rvalid = 0;
    top->m_rid = 0;
    top->m_rlast = 0;
    top->m_rresp = 0;
    for (int i = 0; i < 16; ++i)
        top->m_rdata[i] = 0;

    drive_device_axi_idle(top);

    top->gpu_dcr_req_ready = 1;
    top->gpu_dcr_rsp_valid = 0;
    top->gpu_dcr_rsp_data = 0;
    top->gpu_busy = 0;
}

template <typename T>
static void cycle(vl_simulator<T>& sim, AxiSlave& slave, GpuModel& gpu,
                  uint64_t& tick, PerfCounters* perf = nullptr) {
    auto* top = sim.operator->();
    slave.comb_drive(top);
    gpu.comb_drive(top);
    drive_device_axi_idle(top);
    top->eval();
    slave.comb_drive(top);
    gpu.comb_drive(top);
    drive_device_axi_idle(top);
    top->eval();
    if (perf)
        perf->sample(top);
    slave.posedge_update(top);
    gpu.posedge_update(top);
    tick = sim.step(tick, 2);
    slave.comb_drive(top);
    gpu.comb_drive(top);
    drive_device_axi_idle(top);
    top->eval();
}

template <typename T>
static void axil_write(vl_simulator<T>& sim, AxiSlave& slave, GpuModel& gpu,
                       uint64_t& tick, uint16_t addr, uint32_t data,
                       PerfCounters* perf = nullptr) {
    sim->s_awvalid = 1;
    sim->s_awaddr = addr;
    sim->s_wvalid = 1;
    sim->s_wdata = data;
    sim->s_wstrb = 0xF;
    sim->s_bready = 1;
    bool aw_done = false;
    bool w_done = false;
    for (int g = 0; g < 32; ++g) {
        cycle(sim, slave, gpu, tick, perf);
        if (!aw_done && sim->s_awready) {
            aw_done = true;
            sim->s_awvalid = 0;
        }
        if (!w_done && sim->s_wready) {
            w_done = true;
            sim->s_wvalid = 0;
        }
        if (aw_done && w_done && sim->s_bvalid) {
            sim->s_bready = 0;
            return;
        }
    }
    EXPECT(false, "axil_write: B never asserted within 32 cycles");
}

template <typename T>
static uint32_t axil_read(vl_simulator<T>& sim, AxiSlave& slave, GpuModel& gpu,
                          uint64_t& tick, uint16_t addr) {
    sim->s_arvalid = 1;
    sim->s_araddr = addr;
    sim->s_rready = 1;
    bool ar_done = false;
    uint32_t captured = 0;
    for (int g = 0; g < 32; ++g) {
        cycle(sim, slave, gpu, tick);
        if (!ar_done && sim->s_arready) {
            ar_done = true;
            sim->s_arvalid = 0;
        }
        if (sim->s_rvalid) {
            captured = sim->s_rdata;
            sim->s_rready = 0;
            return captured;
        }
    }
    EXPECT(false, "axil_read: R never asserted");
    return 0;
}

static constexpr uint16_t CP_CTRL          = 0x000;
static constexpr uint16_t CP_DEV_CAPS      = 0x008;
static constexpr uint16_t Q0_BASE          = 0x100;
static constexpr uint16_t Q_RING_BASE_LO   = 0x00;
static constexpr uint16_t Q_RING_BASE_HI   = 0x04;
static constexpr uint16_t Q_CMPL_ADDR_LO   = 0x10;
static constexpr uint16_t Q_CMPL_ADDR_HI   = 0x14;
static constexpr uint16_t Q_RING_SIZE_LOG2 = 0x18;
static constexpr uint16_t Q_CONTROL        = 0x1C;
static constexpr uint16_t Q_TAIL_LO        = 0x20;
static constexpr uint16_t Q_TAIL_HI        = 0x24;

static double ratio(uint64_t num, uint64_t den) {
    return den ? static_cast<double>(num) / static_cast<double>(den) : 0.0;
}

static void print_perf_line(const Workload& wl, const PerfCounters& perf,
                            const GpuModel& gpu) {
    uint64_t fetch_bytes = perf.fetch_cache_lines * CL_BYTES;
    double cmd_per_cycle = ratio(perf.retired_commands, perf.total_cycles);
    double cpc = ratio(perf.total_cycles, perf.retired_commands);
    double bytes_per_command = ratio(fetch_bytes, perf.retired_commands);

    std::printf(
        "CP_PERF,%s,%d,%zu,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ","
        "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ","
        "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ","
        "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ","
        "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ","
        "%.6f,%.6f,%" PRIu64 ",%.6f,%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n",
        wl.id.c_str(), wl.requested_units, wl.cmds.size(),
        perf.submitted_commands, perf.retired_commands, perf.total_cycles,
        perf.idle_cycles, perf.decode_cycles, perf.bid_cycles,
        perf.wait_done_cycles, perf.retire_cycles,
        perf.kmu_wait_cycles, perf.dma_wait_cycles, perf.dcr_wait_cycles,
        perf.event_wait_cycles, perf.fetch_cache_lines, perf.fetch_wait_cycles,
        perf.completion_stall_cycles, perf.arb_wait_cycles,
        perf.queue_latency_cycles, perf.execution_latency_cycles,
        perf.total_latency_cycles, perf.latency_samples,
        cmd_per_cycle, cpc, fetch_bytes, bytes_per_command,
        gpu.dcr_writes, gpu.dcr_reads, gpu.launches);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Options opt = parse_args(argc, argv);
    Workload wl = make_workload(opt);

    vl_simulator<VVX_cp_core_top> sim;
    uint64_t tick = 0;
    AxiSlave slave;
    GpuModel gpu;
    PerfCounters perf;

    init_inputs(sim.operator->());
    tick = sim.reset(tick);

    uint32_t caps = axil_read(sim, slave, gpu, tick, CP_DEV_CAPS);
    EXPECT((caps & 0xff) == 1, "DEV_CAPS NUM_QUEUES");

    uint64_t tail = seed_ring(slave, wl);
    EXPECT(tail > 0, "ring tail is zero");
    slave.mem_write64(CMPL_ADDR, 0xFFFFFFFFFFFFFFFFull);

    axil_write(sim, slave, gpu, tick, Q0_BASE + Q_RING_BASE_LO,
               static_cast<uint32_t>(RING_BASE & 0xffffffffu));
    axil_write(sim, slave, gpu, tick, Q0_BASE + Q_RING_BASE_HI,
               static_cast<uint32_t>(RING_BASE >> 32));
    axil_write(sim, slave, gpu, tick, Q0_BASE + Q_CMPL_ADDR_LO,
               static_cast<uint32_t>(CMPL_ADDR & 0xffffffffu));
    axil_write(sim, slave, gpu, tick, Q0_BASE + Q_CMPL_ADDR_HI,
               static_cast<uint32_t>(CMPL_ADDR >> 32));
    axil_write(sim, slave, gpu, tick, Q0_BASE + Q_RING_SIZE_LOG2, 12);
    axil_write(sim, slave, gpu, tick, Q0_BASE + Q_CONTROL,
               1u | (2u << 2) | (opt.profile ? (1u << 4) : 0u));
    axil_write(sim, slave, gpu, tick, CP_CTRL, 1);

    uint32_t rb_lo = axil_read(sim, slave, gpu, tick, Q0_BASE + Q_RING_BASE_LO);
    uint32_t ctrl  = axil_read(sim, slave, gpu, tick, Q0_BASE + Q_CONTROL);
    uint32_t cp    = axil_read(sim, slave, gpu, tick, CP_CTRL);
    EXPECT(rb_lo == static_cast<uint32_t>(RING_BASE), "ring_base_lo mismatch");
    EXPECT((ctrl & 0x1u) != 0, "queue was not enabled");
    EXPECT((cp & 0x1u) != 0, "CP global enable was not set");

    axil_write(sim, slave, gpu, tick, Q0_BASE + Q_TAIL_LO,
               static_cast<uint32_t>(tail & 0xffffffffu));
    perf.enabled = true;
    axil_write(sim, slave, gpu, tick, Q0_BASE + Q_TAIL_HI,
               static_cast<uint32_t>(tail >> 32), &perf);

    const uint64_t expected_retired = wl.cmds.size();
    const uint64_t expected_seq = expected_retired - 1;
    bool got = false;
    int timeout = 2000 + static_cast<int>(expected_retired) * 300;
    for (int g = 0; g < timeout && !got; ++g) {
        cycle(sim, slave, gpu, tick, &perf);
        got = (slave.mem_read64(CMPL_ADDR) == expected_seq) &&
              (perf.retired_commands >= expected_retired);
    }
    perf.enabled = false;

    EXPECT(got, "completion did not reach expected seqnum before timeout");
    EXPECT(slave.mem_read64(CMPL_ADDR) == expected_seq, "completion wrote wrong final seqnum");
    EXPECT(perf.submitted_commands == expected_retired, "submitted command count mismatch");
    EXPECT(perf.retired_commands == expected_retired, "retired command count mismatch");
    EXPECT(gpu.dcr_writes == wl.expected_dcr_writes, "DCR_WRITE count mismatch");
    EXPECT(gpu.dcr_reads == wl.expected_dcr_reads, "DCR_READ count mismatch");
    EXPECT(gpu.launches == wl.expected_launches, "LAUNCH count mismatch");

    if (!opt.quiet) {
        std::fprintf(stderr,
            "[verify] workload=%s units=%d ring_tail=%" PRIu64
            " q_ctrl=0x%x cp_ctrl=0x%x dbg_tail=0x%" PRIx64
            " dbg_seq=%" PRIu64 "\n",
            wl.id.c_str(), wl.requested_units, tail, ctrl, cp,
            static_cast<uint64_t>(sim->dbg_q0_tail),
            static_cast<uint64_t>(sim->dbg_q0_seqnum));
    }

    print_perf_line(wl, perf, gpu);
    std::printf("PASSED - CP perf workload=%s commands=%zu cycles=%" PRIu64
                " cpc=%.3f\n",
                wl.id.c_str(), wl.cmds.size(), perf.total_cycles,
                ratio(perf.total_cycles, perf.retired_commands));
    return 0;
}
