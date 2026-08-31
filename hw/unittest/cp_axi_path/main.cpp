// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

// ============================================================================
// Verilator unit test for the fetch → xbar → upstream-AXI path AND the
// completion → xbar → upstream-AXI path (Commit B bundle).
//
// The harness instantiates VX_cp_axi_path_top (fetch + completion + xbar
// wired together) and acts as the upstream AXI4 slave + a synthetic
// host-pinned memory. Per-cycle the harness:
//   - Accepts AR / AW / W requests, latches them, and queues responses.
//   - One cycle later, drives R / B back with rdata sourced from a
//     simple 4 KiB byte-addressed memory model (base 0x1000 = ring,
//     base 0x2000 = cmpl slot).
//
// Test scenarios:
//   1. Fetch reads a ring line containing 1 CMD_NOP+F_PROFILE and
//      streams it to cmd_out; head advances by 64.
//   2. Fetch reads a ring line containing 2 commands; both are emitted
//      to cmd_out in order, with cmd_out_ready handshake; head advances
//      by 64 after the second one.
//   3. Completion converts a retire_evt into an AXI W of the right
//      seqnum to cmpl_addr.
//   4. Concurrent: fetch is mid-line and completion fires — both
//      complete; the xbar interleaves them on the upstream master.
// ============================================================================

#include "vl_simulator.h"
#include "VVX_cp_axi_path_top.h"
#include <array>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <vector>

#ifndef TEST_PREFETCH_DEPTH
#define TEST_PREFETCH_DEPTH 2
#endif

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

// ---- cmd_t bit layout ----
static constexpr int CMD_BITS = 288;
static constexpr int F_PROFILE_BIT = 0;
enum CmdOp : uint8_t {
    OP_NOP       = 0x00,
    OP_LAUNCH    = 0x06,
    OP_DCR_WRITE = 0x04,
};

static unsigned cmd_size(uint8_t op, bool profiled) {
    unsigned base = 4;
    switch (op) {
        case 0x00: base = 4;  break;
        case 0x06: base = 12; break;
        case 0x04: base = 20; break;
        default:   base = 4;  break;
    }
    return base + (profiled ? 8 : 0);
}

static unsigned emit_cmd(uint8_t* cl, unsigned off,
                         uint8_t opcode, uint8_t flags,
                         uint64_t arg0, uint64_t arg1, uint64_t profile_slot) {
    bool profiled = (flags & (1u << F_PROFILE_BIT)) != 0;
    unsigned sz = cmd_size(opcode, profiled);
    unsigned data_bytes = sz - 4 - (profiled ? 8 : 0);
    cl[off + 0] = opcode;
    cl[off + 1] = flags;
    cl[off + 2] = 0;
    cl[off + 3] = 0;
    uint64_t args[2] = { arg0, arg1 };
    for (unsigned i = 0; i < data_bytes; ++i) {
        unsigned w = i / 8;
        unsigned b = i % 8;
        if (w < 2) cl[off + 4 + i] = (uint8_t)(args[w] >> (8 * b));
    }
    if (profiled) {
        for (int i = 0; i < 8; ++i)
            cl[off + sz - 8 + i] = (uint8_t)(profile_slot >> (8*i));
    }
    return off + sz;
}

// ---- cpe_state_t packer ----
// SV packed-struct layout (first member at MSB):
//   [403:340] ring_base       (64)
//   [339:324] ring_size_mask  (16)
//   [323:260] head_addr       (64)
//   [259:196] cmpl_addr       (64)
//   [195:132] tail            (64)
//   [131:68]  head            (64)
//   [67:4]    seqnum          (64)
//   [3:2]     prio            (2)
//   [1]       enabled         (1)
//   [0]       profile_en      (1)
// state_in_packed is 404 bits → VlWide<13> (13 × 32 = 416 bits).
static void set_bits(uint32_t* dst, int start, int bits, uint64_t v) {
    for (int i = 0; i < bits; ++i) {
        int b = start + i;
        int word = b / 32;
        int shift = b % 32;
        uint32_t bit = (v >> i) & 1u;
        dst[word] = (dst[word] & ~(1u << shift)) | (bit << shift);
    }
}

static void pack_state(uint32_t* state_words,
                       uint64_t ring_base, uint16_t ring_size_mask,
                       uint64_t head_addr, uint64_t cmpl_addr,
                       uint64_t tail,
                       bool enabled, uint8_t prio = 0, bool profile_en = false) {
    for (int i = 0; i < 13; ++i) state_words[i] = 0;
    set_bits(state_words, 0,   1,  profile_en);
    set_bits(state_words, 1,   1,  enabled);
    set_bits(state_words, 2,   2,  prio);
    set_bits(state_words, 4,   64, 0);            // seqnum
    set_bits(state_words, 68,  64, 0);            // head (regfile owns this)
    set_bits(state_words, 132, 64, tail);
    set_bits(state_words, 196, 64, cmpl_addr);
    set_bits(state_words, 260, 64, head_addr);
    set_bits(state_words, 324, 16, ring_size_mask);
    set_bits(state_words, 340, 64, ring_base);
}

// ---- cmd_t bit-field reader from the packed cmd_out bus ----
static uint64_t read_cmd_bits(uint32_t* cmd_words, int start, int bits) {
    uint64_t v = 0;
    for (int i = 0; i < bits; ++i) {
        int b = start + i;
        uint32_t bit = (cmd_words[b / 32] >> (b % 32)) & 1u;
        v |= (uint64_t)bit << i;
    }
    return v;
}

template <typename T>
static uint8_t cmd_opcode(T* top) {
    return (uint8_t)(read_cmd_bits(top->cmd_out_packed, 256, 32) & 0xff);
}

template <typename T>
static uint8_t cmd_flags(T* top) {
    return (uint8_t)((read_cmd_bits(top->cmd_out_packed, 256, 32) >> 8) & 0xff);
}

template <typename T>
static uint64_t cmd_arg0(T* top) {
    return read_cmd_bits(top->cmd_out_packed, 192, 64);
}

// ============================================================================
// Synthetic AXI4 slave: 4 KiB byte-addressed memory. Handles ordered AR→R
// with configurable latency and AW+W→B with a 1-cycle latency. Split into:
//   - comb_drive(): write slave-driven inputs (the *ready / *valid / *data
//     outputs from the slave's perspective) based on current internal state.
//     Called every eval so master combinational logic sees consistent
//     slave-driven signals.
//   - posedge_update(): sample handshakes and update internal state on a
//     rising-edge boundary. Called once per cycle.
// ============================================================================
struct AxiSlave {
    static constexpr uint64_t MEM_BASE = 0x1000;
    static constexpr int      MEM_SIZE = 4096;
    uint8_t mem[MEM_SIZE] = {0};
    std::vector<uint64_t> ar_addresses;

    int          read_latency = 1;
    struct ReadRequest {
        uint64_t addr;
        uint8_t id;
        int delay;
    };
    std::deque<ReadRequest> read_requests;

    // AW/W state.
    bool         aw_taken   = false;
    uint64_t     aw_addr    = 0;
    uint8_t      aw_id      = 0;

    bool         b_pending  = false;
    uint8_t      b_id       = 0;

    void mem_write(uint64_t addr, uint64_t data, int bytes = 8) {
        for (int i = 0; i < bytes; ++i) {
            int64_t a = (int64_t)addr - (int64_t)MEM_BASE + i;
            if (a >= 0 && a < MEM_SIZE) mem[a] = (uint8_t)(data >> (8 * i));
        }
    }

    uint64_t mem_read64(uint64_t addr) const {
        uint64_t v = 0;
        for (int i = 0; i < 8; ++i) {
            int64_t a = (int64_t)addr - (int64_t)MEM_BASE + i;
            if (a >= 0 && a < MEM_SIZE) v |= (uint64_t)mem[a] << (8 * i);
        }
        return v;
    }

    void mem_write_cl(uint64_t addr, const uint8_t* src) {
        for (int i = 0; i < 64; ++i) {
            int64_t a = (int64_t)addr - (int64_t)MEM_BASE + i;
            if (a >= 0 && a < MEM_SIZE) mem[a] = src[i];
        }
    }

    void mem_read_cl(uint64_t addr, uint32_t* dst) const {
        for (int w = 0; w < 16; ++w) {
            uint32_t v = 0;
            for (int b = 0; b < 4; ++b) {
                int64_t a = (int64_t)addr - (int64_t)MEM_BASE + w*4 + b;
                if (a >= 0 && a < MEM_SIZE) v |= (uint32_t)mem[a] << (8 * b);
            }
            dst[w] = v;
        }
    }

    // ---- Combinational drive: slave → master inputs ----
    template <typename T>
    void comb_drive(T* top) {
        // 接受少量有序在途请求，响应仍严格保持 AR 顺序。
        top->m_arready = read_requests.size() < 16;
        top->m_rvalid = !read_requests.empty()
                     && (read_requests.front().delay == 0);
        top->m_rid    = read_requests.empty() ? 0 : read_requests.front().id;
        top->m_rlast  = 1;
        top->m_rresp  = 0;
        if (top->m_rvalid)
            mem_read_cl(read_requests.front().addr, top->m_rdata);

        // AW side.
        top->m_awready = !aw_taken;
        // W side: only ready when AW is captured and B not yet pending.
        top->m_wready = aw_taken && !b_pending;

        // B side.
        top->m_bvalid = b_pending;
        top->m_bid    = b_id;
        top->m_bresp  = 0;
    }

    // ---- Rising-edge state update ----
    template <typename T>
    void posedge_update(T* top) {
        // Accept new AR.
        if (top->m_arvalid && top->m_arready) {
            read_requests.push_back(
                {top->m_araddr, static_cast<uint8_t>(top->m_arid), read_latency});
            ar_addresses.push_back(top->m_araddr);
        }
        const bool pop_response = top->m_rvalid && top->m_rready;
        for (auto& request : read_requests)
            if (request.delay > 0) --request.delay;
        if (pop_response)
            read_requests.pop_front();

        // Accept new AW.
        if (top->m_awvalid && top->m_awready) {
            aw_taken = true;
            aw_addr  = top->m_awaddr;
            aw_id    = top->m_awid;
        }
        // W handshake completes the write.
        if (aw_taken && top->m_wvalid && top->m_wready) {
            uint64_t v = ((uint64_t)top->m_wdata[1] << 32) | top->m_wdata[0];
            mem_write(aw_addr, v, 8);
            aw_taken  = false;
            b_pending = true;
            b_id      = aw_id;
        }
        // B handshake.
        if (b_pending && top->m_bvalid && top->m_bready) {
            b_pending = false;
        }
    }
};

struct Options {
    int latency = 1;
    int benchmark_lines = 0;
};

static int parse_nonnegative(const char* text, const char* name) {
    char* end = nullptr;
    long value = std::strtol(text, &end, 10);
    if (*text == '\0' || *end != '\0' || value < 0 || value > 100000) {
        std::fprintf(stderr, "Invalid %s: %s\n", name, text);
        std::exit(2);
    }
    return static_cast<int>(value);
}

static Options parse_options(int argc, char** argv) {
    Options opt;
    for (int i = 1; i < argc; ++i) {
        constexpr const char* latency_prefix = "--latency=";
        constexpr const char* lines_prefix = "--benchmark-lines=";
        if (std::strncmp(argv[i], latency_prefix,
                         std::strlen(latency_prefix)) == 0) {
            opt.latency = parse_nonnegative(
                argv[i] + std::strlen(latency_prefix), "--latency");
        } else if (std::strncmp(argv[i], lines_prefix,
                                std::strlen(lines_prefix)) == 0) {
            opt.benchmark_lines = parse_nonnegative(
                argv[i] + std::strlen(lines_prefix), "--benchmark-lines");
        } else if (std::strcmp(argv[i], "--help") == 0) {
            std::printf("Usage: %s [--latency=N] [--benchmark-lines=N]\n",
                        argv[0]);
            std::exit(0);
        }
    }
    return opt;
}

// Advance one full clock cycle. Order:
//   1. Settle combinational with current slave state.
//   2. Sample handshakes at the "rising edge" (update slave + simulator FFs).
//   3. Settle again so all outputs reflect the new state.
template <typename T>
static void cycle(vl_simulator<T>& sim, AxiSlave& s, uint64_t& tick) {
    auto* top = sim.operator->();
    s.comb_drive(top);
    top->eval();
    s.comb_drive(top);
    top->eval();
    s.posedge_update(top);
    tick = sim.step(tick, 2);
    s.comb_drive(top);
    top->eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const Options opt = parse_options(argc, argv);
    trace_en = std::getenv("VCD_FILE") != nullptr;
    vl_simulator<VVX_cp_axi_path_top> sim;
    uint64_t tick = 0;
    AxiSlave slave;
    slave.read_latency = opt.latency;

    // Defaults.
    sim->cmd_out_ready = 0;
    sim->retire_evt = 0;
    sim->retire_seqnum = 0;
    sim->cmpl_addr = 0;
    for (int i = 0; i < 13; ++i) sim->state_in_packed[i] = 0;
    tick = sim.reset(tick);

    if (opt.benchmark_lines != 0) {
        EXPECT(opt.benchmark_lines <= AxiSlave::MEM_SIZE / 64,
               "benchmark ring exceeds synthetic memory");
        for (int line = 0; line < opt.benchmark_lines; ++line) {
            uint8_t cl[64] = {0};
            for (int slot = 0; slot < 3; ++slot) {
                const uint64_t index = static_cast<uint64_t>(line * 3 + slot);
                emit_cmd(cl, slot * 20, OP_DCR_WRITE, 0,
                         0x1000ull + index, 0xA000ull + index, 0);
            }
            slave.mem_write_cl(AxiSlave::MEM_BASE + line * 64, cl);
        }

        uint32_t s[13];
        const uint64_t tail = static_cast<uint64_t>(opt.benchmark_lines) * 64;
        pack_state(s, AxiSlave::MEM_BASE, 0x0FFF, 0,
                   AxiSlave::MEM_BASE + 0x800, tail, true);
        for (int i = 0; i < 13; ++i) sim->state_in_packed[i] = s[i];
        sim->cmd_out_ready = 1;

        const uint64_t expected_commands =
            static_cast<uint64_t>(opt.benchmark_lines) * 3;
        uint64_t emitted = 0;
        uint64_t cycles = 0;
        const uint64_t cycle_limit =
            static_cast<uint64_t>(opt.benchmark_lines)
          * static_cast<uint64_t>(opt.latency + 16) + 100;
        while (sim->head_out != tail && cycles < cycle_limit) {
            cycle(sim, slave, tick);
            ++cycles;
            if (sim->cmd_out_valid) {
                EXPECT(cmd_opcode(sim.operator->()) == OP_DCR_WRITE,
                       "benchmark opcode mismatch");
                EXPECT(cmd_arg0(sim.operator->()) == 0x1000ull + emitted,
                       "benchmark command order mismatch");
                ++emitted;
            }
        }
        EXPECT(sim->head_out == tail, "benchmark head did not reach tail");
        EXPECT(emitted == expected_commands,
               "benchmark emitted command count mismatch");
        EXPECT(slave.ar_addresses.size()
                   == static_cast<size_t>(opt.benchmark_lines),
               "benchmark AR count mismatch");
        for (int i = 0; i < opt.benchmark_lines; ++i) {
            EXPECT(slave.ar_addresses[i]
                       == AxiSlave::MEM_BASE + static_cast<uint64_t>(i) * 64,
                   "benchmark AR address sequence mismatch");
        }
        std::printf(
            "PREFETCH_RESULT depth=%d latency=%d cache_lines=%d commands=%" PRIu64
            " ar_count=%zu total_cycles=%" PRIu64 " cmd_per_cycle=%.6f"
            " final_head=%" PRIu64 " dropped_count=0 duplicate_count=0\n",
            TEST_PREFETCH_DEPTH, opt.latency, opt.benchmark_lines,
            expected_commands, slave.ar_addresses.size(), cycles,
            static_cast<double>(expected_commands) / cycles,
            static_cast<uint64_t>(sim->head_out));
        return 0;
    }

    // ----- Test 1: ring with 1 CMD_NOP+F_PROFILE; fetch + decode + emit -----
    {
        uint8_t cl[64] = {0};
        emit_cmd(cl, 0, OP_NOP, (1u << F_PROFILE_BIT),
                 /*arg0=*/0, /*arg1=*/0, /*profile_slot=*/0xABCDEFull);
        slave.mem_write_cl(AxiSlave::MEM_BASE, cl);

        // ring_base = MEM_BASE; ring_size_mask = 0xFFF (4 KiB); tail = 64.
        uint32_t s[13];
        pack_state(s, AxiSlave::MEM_BASE, 0x0FFF,
                   /*head_addr=*/0, /*cmpl_addr=*/AxiSlave::MEM_BASE + 0x100,
                   /*tail=*/64, /*enabled=*/true);
        for (int i = 0; i < 13; ++i) sim->state_in_packed[i] = s[i];

        // Run until cmd_out_valid; cap at 50 cycles.
        bool got = false;
        for (int c = 0; c < 50 && !got; ++c) {
            cycle(sim, slave, tick);
            if (sim->cmd_out_valid) got = true;
        }
        EXPECT(got, "T1: cmd_out_valid never asserted");
        EXPECT(cmd_opcode(sim.operator->()) == OP_NOP, "T1: opcode");
        EXPECT(cmd_flags (sim.operator->()) == (1u << F_PROFILE_BIT), "T1: F_PROFILE");

        // Handshake the command out; FSM should advance head and return
        // to IDLE.
        sim->cmd_out_ready = 1;
        cycle(sim, slave, tick);
        sim->cmd_out_ready = 0;
        for (int c = 0; c < 5; ++c) cycle(sim, slave, tick);
        EXPECT(sim->head_out == 64, "T1: head should advance to 64");
    }

    // ----- Test 2: ring with 2 commands; both emitted in order -----
    {
        uint8_t cl[64] = {0};
        unsigned off = 0;
        off = emit_cmd(cl, off, OP_LAUNCH, 0, /*arg0=*/0x80000000ull, 0, 0);
        off = emit_cmd(cl, off, OP_DCR_WRITE, 0, /*arg0=addr=*/0x123ull,
                       /*arg1=val=*/0xDEADBEEFull, 0);
        // off should be 12 (LAUNCH) + 20 (DCR_WRITE) = 32 bytes.
        slave.mem_write_cl(AxiSlave::MEM_BASE + 64, cl);

        // tail = 128 (one more line beyond the first).
        uint32_t s[13];
        pack_state(s, AxiSlave::MEM_BASE, 0x0FFF,
                   /*head_addr=*/0, /*cmpl_addr=*/AxiSlave::MEM_BASE + 0x100,
                   /*tail=*/128, /*enabled=*/true);
        for (int i = 0; i < 13; ++i) sim->state_in_packed[i] = s[i];

        // First cmd: LAUNCH.
        bool got = false;
        for (int c = 0; c < 50 && !got; ++c) {
            cycle(sim, slave, tick);
            if (sim->cmd_out_valid) got = true;
        }
        EXPECT(got, "T2: first cmd_out_valid never asserted");
        EXPECT(cmd_opcode(sim.operator->()) == OP_LAUNCH, "T2: first opcode = LAUNCH");
        sim->cmd_out_ready = 1;
        cycle(sim, slave, tick);
        sim->cmd_out_ready = 0;

        // Second cmd: DCR_WRITE.
        got = false;
        for (int c = 0; c < 20 && !got; ++c) {
            cycle(sim, slave, tick);
            if (sim->cmd_out_valid) got = true;
        }
        EXPECT(got, "T2: second cmd_out_valid never asserted");
        EXPECT(cmd_opcode(sim.operator->()) == OP_DCR_WRITE,
               "T2: second opcode = DCR_WRITE");
        sim->cmd_out_ready = 1;
        cycle(sim, slave, tick);
        sim->cmd_out_ready = 0;

        for (int c = 0; c < 5; ++c) cycle(sim, slave, tick);
        EXPECT(sim->head_out == 128, "T2: head should advance to 128");
    }

    // ----- 测试 3：小 ring 连续读取跨越回绕边界 -----
    {
        const uint64_t expected_addr[4] = {
            AxiSlave::MEM_BASE + 128,
            AxiSlave::MEM_BASE + 192,
            AxiSlave::MEM_BASE,
            AxiSlave::MEM_BASE + 64,
        };
        for (int i = 0; i < 4; ++i) {
            uint8_t cl[64] = {0};
            for (int j = 0; j < 3; ++j) {
                emit_cmd(cl, j * 20, OP_DCR_WRITE, 0,
                         0x100ull + i * 3 + j,
                         0x5000ull + i * 3 + j, 0);
            }
            slave.mem_write_cl(expected_addr[i], cl);
        }

        const size_t ar_start = slave.ar_addresses.size();
        uint32_t s[13];
        pack_state(s, AxiSlave::MEM_BASE, 0x00FF,
                   0, AxiSlave::MEM_BASE + 0x300,
                   /*tail=*/384, /*enabled=*/true);
        for (int i = 0; i < 13; ++i) sim->state_in_packed[i] = s[i];

        for (int i = 0; i < 12; ++i) {
            bool got = false;
            for (int c = 0; c < 50 && !got; ++c) {
                cycle(sim, slave, tick);
                got = sim->cmd_out_valid;
            }
            EXPECT(got, "T3: wrapped command was not emitted");
            EXPECT(cmd_opcode(sim.operator->()) == OP_DCR_WRITE,
                   "T3: wrapped packed opcode");
            sim->cmd_out_ready = 1;
            cycle(sim, slave, tick);
            sim->cmd_out_ready = 0;
        }
        for (int c = 0; c < 8; ++c) cycle(sim, slave, tick);
        EXPECT(sim->head_out == 384, "T3: head should cross wrap to 384");
        EXPECT(slave.ar_addresses.size() == ar_start + 4,
               "T3: expected exactly four wrapped reads");
        for (int i = 0; i < 4; ++i)
            EXPECT(slave.ar_addresses[ar_start + i] == expected_addr[i],
                   "T3: wrapped AXI address mismatch");
    }

    // ----- 测试 4：completion 将 retire_seqnum 写入 cmpl_addr -----
    {
        // Drive cpe_state with enabled=0 to keep fetch idle.
        uint32_t s[13];
        pack_state(s, AxiSlave::MEM_BASE, 0x0FFF,
                   0, /*cmpl_addr=*/AxiSlave::MEM_BASE + 0x200,
                   0, /*enabled=*/false);
        for (int i = 0; i < 13; ++i) sim->state_in_packed[i] = s[i];

        sim->retire_seqnum = 42;
        sim->cmpl_addr     = AxiSlave::MEM_BASE + 0x200;
        sim->retire_evt    = 1;
        cycle(sim, slave, tick);
        sim->retire_evt    = 0;

        // Wait for the AXI W → memory.
        bool wrote = false;
        for (int c = 0; c < 30 && !wrote; ++c) {
            cycle(sim, slave, tick);
            if (slave.mem_read64(AxiSlave::MEM_BASE + 0x200) == 42) wrote = true;
        }
        EXPECT(wrote, "T4: completion did not write seqnum to cmpl_addr");
    }

    std::printf("PASSED — 4 scenarios\n");
    return 0;
}
