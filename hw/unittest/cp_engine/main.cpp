// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

// ============================================================================
// Verilator unit test for VX_cp_engine.
//
// Drives synthetic cmd_t values into the engine and verifies the FSM:
//
//   - IDLE -> RETIRE               for CMD_NOP when fast path is enabled
//   - IDLE -> DECODE -> RETIRE     for CMD_NOP baseline / CMD_FENCE
//   - IDLE -> DECODE -> BID -> WAIT_DONE -> RETIRE for the resource opcodes
//
// Per opcode → resource classification (cmd:[7:0] header.opcode):
//
//   0x00 NOP            -> no bid, retires immediately
//   0x01 MEM_WRITE      -> bid_dma
//   0x02 MEM_READ       -> bid_dma
//   0x03 MEM_COPY       -> bid_dma
//   0x04 DCR_WRITE      -> bid_dcr
//   0x05 DCR_READ       -> bid_dcr
//   0x06 LAUNCH         -> bid_kmu
//   0x07 FENCE          -> no bid, retires immediately
//   0x08 EVENT_SIGNAL   -> bid EVENT
//   0x09 EVENT_WAIT     -> bid EVENT
//
// Also asserts:
//   - retire_seqnum monotonically increments by 1 per retired command
//   - profiling pulses (submit/start/end) fire exactly when F_PROFILE is set
//   - state_prio propagates into the bid line priority field
// ============================================================================

#include "vl_simulator.h"
#include "VVX_cp_engine_top.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
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

// cmd_t is a SystemVerilog packed struct. By the language rules, the first
// member declared sits in the most-significant bits. So the bit layout
// across cmd_in_packed[287:0] is:
//
//   [287:256]  hdr  =  reserved[15:0] | flags[7:0] | opcode[7:0]
//   [255:192]  arg0
//   [191:128]  arg1
//   [127:64]   arg2
//   [63:0]     profile_slot
//
// Verilator exposes the 288-bit signal as a VlWide<9> array of uint32_t
// (LSB word at index 0). So profile_slot lands in words[0..1] and the
// header lands in words[8].

enum CmdOp : uint8_t {
    OP_NOP        = 0x00,
    OP_MEM_WRITE  = 0x01,
    OP_MEM_READ   = 0x02,
    OP_MEM_COPY   = 0x03,
    OP_DCR_WRITE  = 0x04,
    OP_DCR_READ   = 0x05,
    OP_LAUNCH     = 0x06,
    OP_FENCE      = 0x07,
    OP_EVT_SIG    = 0x08,
    OP_EVT_WAIT   = 0x09,
};

enum EngineState : uint8_t {
    ENG_IDLE = 0,
    ENG_DECODE = 1,
    ENG_BID = 2,
    ENG_WAIT_DONE = 3,
    ENG_RETIRE = 4
};

static constexpr uint8_t F_PROFILE_BIT = 0;

static void pack_cmd(uint32_t out_words[9],
                     uint8_t opcode, uint8_t flags,
                     uint64_t arg0, uint64_t arg1, uint64_t arg2,
                     uint64_t profile_slot) {
    for (int i = 0; i < 9; ++i) out_words[i] = 0;
    // [63:0] profile_slot (last field of cmd_t)
    out_words[0]  = static_cast<uint32_t>(profile_slot & 0xffffffffu);
    out_words[1]  = static_cast<uint32_t>(profile_slot >> 32);
    // [127:64] arg2
    out_words[2]  = static_cast<uint32_t>(arg2 & 0xffffffffu);
    out_words[3]  = static_cast<uint32_t>(arg2 >> 32);
    // [191:128] arg1
    out_words[4]  = static_cast<uint32_t>(arg1 & 0xffffffffu);
    out_words[5]  = static_cast<uint32_t>(arg1 >> 32);
    // [255:192] arg0
    out_words[6]  = static_cast<uint32_t>(arg0 & 0xffffffffu);
    out_words[7]  = static_cast<uint32_t>(arg0 >> 32);
    // [287:256] hdr  =  reserved[31:16] | flags[15:8] | opcode[7:0]
    out_words[8]  = static_cast<uint32_t>(opcode) |
                    (static_cast<uint32_t>(flags) << 8);
}

template <typename T>
static void set_cmd(T* top, uint8_t opcode, uint8_t flags = 0,
                    uint64_t arg0 = 0, uint64_t arg1 = 0, uint64_t arg2 = 0,
                    uint64_t profile_slot = 0) {
    uint32_t words[9];
    pack_cmd(words, opcode, flags, arg0, arg1, arg2, profile_slot);
    for (int i = 0; i < 9; ++i) top->cmd_in_packed[i] = words[i];
}

#define EXPECT(cond, msg) do { \
    if (!(cond)) { \
        std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg); \
        std::exit(1); \
    } \
} while (0)

// Drive inputs, evaluate combinational (sample outputs for the current
// cycle), then advance one clock edge so FF state updates take effect for
// the next call.
template <typename T>
static void cycle(vl_simulator<T>& sim, uint64_t& tick) {
    sim->eval();
    tick = sim.step(tick, 2);
}

// Drive a single command into the engine and run the FSM to completion.
// `expect_*_bid` say which resource line should fire during the BID state
// (or zero of them for skip-opcodes). Verifies seqnum monotonicity and
// profiling pulses. Returns the new expected seqnum.
template <typename T>
static uint64_t run_one_cmd(vl_simulator<T>& sim, uint64_t& tick,
                            uint8_t opcode, uint8_t flags,
                            bool expect_kmu, bool expect_dma,
                            bool expect_dcr, bool expect_event,
                            uint64_t prior_seqnum) {
    // ----- Pre-condition: engine in IDLE -----
    sim->cmd_in_valid = 0;
    set_cmd(sim.operator->(), 0);
    sim->bid_kmu_grant   = 0;
    sim->bid_dma_grant   = 0;
    sim->bid_dcr_grant   = 0;
    sim->bid_event_grant = 0;
    sim->eval();
    EXPECT(sim->cmd_in_ready == 1, "engine not in IDLE before cmd");

    // ----- Cycle 1: present command and capture it from IDLE -----
    sim->cmd_in_valid = 1;
    set_cmd(sim.operator->(), opcode, flags, /*arg0=*/0xCAFEBABEull,
            /*arg1=*/0, /*arg2=*/0, /*profile_slot=*/0xDEADBEEFull);
    sim->eval();
    bool prof = (flags & (1u << F_PROFILE_BIT)) != 0;
    bool submit_at_accept = sim->submit_evt != 0;
    cycle(sim, tick);

    sim->cmd_in_valid = 0;
    set_cmd(sim.operator->(), 0);

    // Baseline commands report submit in DECODE. A fast-path profiled NOP
    // reports it on the acceptance cycle instead.
    sim->eval();
    bool submit_at_decode = sim->submit_evt != 0;
    EXPECT((submit_at_accept || submit_at_decode) == prof,
           "submit_evt missing for profiled command");
    EXPECT(!(submit_at_accept && submit_at_decode),
           "submit_evt pulsed more than once");

    bool any_bid = expect_kmu || expect_dma || expect_dcr || expect_event;

    const bool fast_nop = opcode == OP_NOP && sim->nop_fast_path;
    if (!fast_nop) {
        // ----- DECODE -----
        cycle(sim, tick);
    }

    if (any_bid) {
        // ----- Cycle 3: BID -----
        // The expected bid line is asserted; others are not.
        sim->eval();
        if (expect_kmu) {
            EXPECT(sim->bid_kmu_valid   == 1, "expected bid_kmu_valid high");
            EXPECT(sim->bid_dma_valid   == 0, "expected bid_dma_valid low");
            EXPECT(sim->bid_dcr_valid   == 0, "expected bid_dcr_valid low");
            EXPECT(sim->bid_event_valid == 0, "expected bid_event_valid low");
        } else if (expect_dma) {
            EXPECT(sim->bid_kmu_valid   == 0, "expected bid_kmu_valid low");
            EXPECT(sim->bid_dma_valid   == 1, "expected bid_dma_valid high");
            EXPECT(sim->bid_dcr_valid   == 0, "expected bid_dcr_valid low");
            EXPECT(sim->bid_event_valid == 0, "expected bid_event_valid low");
        } else if (expect_dcr) {
            EXPECT(sim->bid_kmu_valid   == 0, "expected bid_kmu_valid low");
            EXPECT(sim->bid_dma_valid   == 0, "expected bid_dma_valid low");
            EXPECT(sim->bid_dcr_valid   == 1, "expected bid_dcr_valid high");
            EXPECT(sim->bid_event_valid == 0, "expected bid_event_valid low");
        } else if (expect_event) {
            EXPECT(sim->bid_kmu_valid   == 0, "expected bid_kmu_valid low");
            EXPECT(sim->bid_dma_valid   == 0, "expected bid_dma_valid low");
            EXPECT(sim->bid_dcr_valid   == 0, "expected bid_dcr_valid low");
            EXPECT(sim->bid_event_valid == 1, "expected bid_event_valid high");
        }

        // Grant immediately; FSM transitions to WAIT_DONE at edge.
        if (expect_kmu)   sim->bid_kmu_grant   = 1;
        if (expect_dma)   sim->bid_dma_grant   = 1;
        if (expect_dcr)   sim->bid_dcr_grant   = 1;
        if (expect_event) sim->bid_event_grant = 1;
        sim->eval();

        // start_evt pulses iff F_PROFILE && (cur_res granted).
        EXPECT((sim->start_evt != 0) == prof, "start_evt mismatch");
        cycle(sim, tick);

        sim->bid_kmu_grant   = 0;
        sim->bid_dma_grant   = 0;
        sim->bid_dcr_grant   = 0;
        sim->bid_event_grant = 0;

        // ----- Cycle 4: WAIT_DONE -> pulse done -> RETIRE -----
        // Engine waits for the resource's done pulse before retiring.
        // Simulate a one-cycle done pulse here.
        if (expect_kmu)   sim->kmu_done_i   = 1;
        if (expect_dma)   sim->dma_done_i   = 1;
        if (expect_dcr)   sim->dcr_done_i   = 1;
        if (expect_event) sim->event_done_i = 1;
        cycle(sim, tick);
        sim->kmu_done_i   = 0;
        sim->dma_done_i   = 0;
        sim->dcr_done_i   = 0;
        sim->event_done_i = 0;
    }

    // ----- RETIRE cycle: retire_evt high, seqnum still old value -----
    sim->eval();
    EXPECT(sim->retire_evt == 1, "retire_evt did not fire");
    EXPECT(sim->retire_seqnum == prior_seqnum, "seqnum should not yet have advanced");
    EXPECT((sim->end_evt != 0) == prof, "end_evt mismatch");
    if (prof) {
        EXPECT(sim->profile_slot == 0xDEADBEEFull, "profile_slot did not propagate");
    }
    cycle(sim, tick);

    // After RETIRE, FSM is IDLE and seqnum has incremented.
    sim->eval();
    EXPECT(sim->cmd_in_ready == 1, "engine did not return to IDLE");
    EXPECT(sim->retire_seqnum == prior_seqnum + 1, "seqnum did not increment");
    EXPECT(sim->seqnum_out == prior_seqnum + 1, "seqnum_out did not increment");
    EXPECT(sim->retire_evt == 0, "retire_evt should not stick");

    return prior_seqnum + 1;
}

struct NopMetrics {
    uint64_t command_count = 0;
    uint64_t retire_count = 0;
    uint64_t final_seqnum = 0;
    uint64_t duplicate_count = 0;
    uint64_t dropped_count = 0;
    uint64_t total_cycles = 0;
    uint64_t decode_cycles = 0;
    uint64_t retire_cycles = 0;
};

template <typename T>
static NopMetrics run_nop_benchmark(vl_simulator<T>& sim, uint64_t& tick,
                                    uint64_t command_count) {
    NopMetrics result;
    result.command_count = command_count;

    sim->cmd_in_valid = 0;
    set_cmd(sim.operator->(), 0);
    sim->bid_kmu_grant = 0;
    sim->bid_dma_grant = 0;
    sim->bid_dcr_grant = 0;
    sim->bid_event_grant = 0;
    sim->kmu_done_i = 0;
    sim->dma_done_i = 0;
    sim->dcr_done_i = 0;
    sim->event_done_i = 0;
    tick = sim.reset(tick);
    sim->eval();
    EXPECT(sim->seqnum_out == 0, "NOP benchmark did not reset seqnum");

    std::vector<uint8_t> seen(command_count, 0);
    uint64_t submitted = 0;
    bool valid_held = false;
    const uint64_t cycle_limit = command_count * 5 + 20;

    for (uint64_t guard = 0; guard < cycle_limit; ++guard) {
        if (!valid_held && submitted < command_count) {
            sim->cmd_in_valid = 1;
            set_cmd(sim.operator->(), OP_NOP);
            valid_held = true;
        }

        sim->eval();
        switch (sim->engine_fsm) {
        case ENG_DECODE:
            ++result.decode_cycles;
            break;
        case ENG_RETIRE:
            ++result.retire_cycles;
            break;
        default:
            break;
        }

        const bool accepted = sim->cmd_in_valid && sim->cmd_in_ready;
        const bool retired = sim->retire_evt != 0;
        if (accepted)
            ++submitted;

        if (retired) {
            const uint64_t seqnum = sim->retire_seqnum;
            ++result.retire_count;
            if (seqnum < command_count) {
                if (seen[seqnum]) {
                    ++result.duplicate_count;
                } else {
                    seen[seqnum] = 1;
                }
            } else {
                ++result.duplicate_count;
            }
        }

        ++result.total_cycles;
        cycle(sim, tick);

        if (accepted) {
            sim->cmd_in_valid = 0;
            set_cmd(sim.operator->(), 0);
            valid_held = false;
        }

        if (submitted == command_count
            && result.retire_count == command_count) {
            sim->eval();
            break;
        }
    }

    EXPECT(submitted == command_count, "NOP benchmark dropped a command");
    EXPECT(result.retire_count == command_count,
           "NOP benchmark did not retire all commands");

    uint64_t unique_retired = 0;
    for (uint8_t entry : seen)
        unique_retired += entry != 0;
    result.dropped_count = command_count - unique_retired;
    result.final_seqnum = sim->seqnum_out;

    EXPECT(result.final_seqnum == command_count,
           "NOP benchmark final seqnum mismatch");
    EXPECT(result.duplicate_count == 0,
           "NOP benchmark observed duplicate retire");
    EXPECT(result.dropped_count == 0,
           "NOP benchmark observed dropped command");
    EXPECT(sim->engine_fsm == ENG_IDLE,
           "NOP benchmark did not return to IDLE");
    return result;
}

static uint64_t parse_nop_count(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        constexpr const char* prefix = "--nop-count=";
        if (std::strncmp(argv[i], prefix, std::strlen(prefix)) == 0) {
            char* end = nullptr;
            const char* value = argv[i] + std::strlen(prefix);
            uint64_t count = std::strtoull(value, &end, 10);
            if (*value == '\0' || *end != '\0' || count == 0) {
                std::fprintf(stderr, "Invalid --nop-count: %s\n", value);
                std::exit(2);
            }
            return count;
        }
        if (std::strcmp(argv[i], "--help") == 0) {
            std::printf("Usage: %s [--nop-count=N]\n", argv[0]);
            std::exit(0);
        }
    }
    return 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    vl_simulator<VVX_cp_engine_top> sim;
    uint64_t tick = 0;
    const uint64_t only_nop_count = parse_nop_count(argc, argv);

    sim->state_prio   = 0;
    sim->cmd_in_valid = 0;
    set_cmd(sim.operator->(), 0);
    sim->bid_kmu_grant   = 0;
    sim->bid_dma_grant   = 0;
    sim->bid_dcr_grant   = 0;
    sim->bid_event_grant = 0;
    sim->kmu_done_i   = 0;
    sim->dma_done_i   = 0;
    sim->dcr_done_i   = 0;
    sim->event_done_i = 0;
    tick = sim.reset(tick);

    std::printf("ENGINE_CONFIG nop_fast_path=%d\n",
                sim->nop_fast_path ? 1 : 0);

    if (only_nop_count == 0) {
        uint64_t seq = 0;

        seq = run_one_cmd(sim, tick, OP_NOP, 0,
                          false, false, false, false, seq);
        seq = run_one_cmd(sim, tick, OP_LAUNCH, 0,
                          true, false, false, false, seq);
        seq = run_one_cmd(sim, tick, OP_DCR_WRITE, 0,
                          false, false, true, false, seq);
        seq = run_one_cmd(sim, tick, OP_DCR_READ, 0,
                          false, false, true, false, seq);
        seq = run_one_cmd(sim, tick, OP_MEM_WRITE, 0,
                          false, true, false, false, seq);
        seq = run_one_cmd(sim, tick, OP_MEM_READ, 0,
                          false, true, false, false, seq);
        seq = run_one_cmd(sim, tick, OP_MEM_COPY, 0,
                          false, true, false, false, seq);
        seq = run_one_cmd(sim, tick, OP_FENCE, 0,
                          false, false, false, false, seq);
        seq = run_one_cmd(sim, tick, OP_EVT_SIG, 0,
                          false, false, false, true, seq);
        seq = run_one_cmd(sim, tick, OP_EVT_WAIT, 0,
                          false, false, false, true, seq);
        seq = run_one_cmd(sim, tick, OP_NOP, (1u << F_PROFILE_BIT),
                          false, false, false, false, seq);
        seq = run_one_cmd(sim, tick, OP_LAUNCH, (1u << F_PROFILE_BIT),
                          true, false, false, false, seq);

        sim->state_prio = 3;
        sim->cmd_in_valid = 1;
        set_cmd(sim.operator->(), OP_LAUNCH);
        cycle(sim, tick);
        sim->cmd_in_valid = 0;
        set_cmd(sim.operator->(), 0);
        cycle(sim, tick);
        sim->eval();
        EXPECT(sim->bid_kmu_valid == 1, "prio test: bid_kmu_valid high in BID");
        EXPECT(sim->bid_kmu_prio == 3, "state_prio did not propagate");
        sim->bid_kmu_grant = 1;
        cycle(sim, tick);
        sim->bid_kmu_grant = 0;
        sim->kmu_done_i = 1;
        cycle(sim, tick);
        sim->kmu_done_i = 0;
        cycle(sim, tick);
        ++seq;

        std::printf("SMOKE_RESULT commands_retired=%lu\n",
                    (unsigned long)seq);
    }

    const uint64_t counts[] = {100, 1000, 10000};
    if (only_nop_count != 0) {
        const NopMetrics metrics =
            run_nop_benchmark(sim, tick, only_nop_count);
        const double cpc = static_cast<double>(metrics.total_cycles)
                         / metrics.command_count;
        const double throughput =
            static_cast<double>(metrics.command_count) / metrics.total_cycles;
        std::printf(
            "NOP_RESULT command_count=%lu retire_count=%lu final_seqnum=%lu "
            "duplicate_count=%lu dropped_count=%lu total_cycles=%lu "
            "cycles_per_command=%.6f cmd_per_cycle=%.6f decode_cycles=%lu "
            "retire_cycles=%lu\n",
            (unsigned long)metrics.command_count,
            (unsigned long)metrics.retire_count,
            (unsigned long)metrics.final_seqnum,
            (unsigned long)metrics.duplicate_count,
            (unsigned long)metrics.dropped_count,
            (unsigned long)metrics.total_cycles,
            cpc,
            throughput,
            (unsigned long)metrics.decode_cycles,
            (unsigned long)metrics.retire_cycles);
    } else {
        for (uint64_t count : counts) {
            const NopMetrics metrics = run_nop_benchmark(sim, tick, count);
            const double cpc = static_cast<double>(metrics.total_cycles)
                             / metrics.command_count;
            const double throughput =
                static_cast<double>(metrics.command_count) / metrics.total_cycles;
            std::printf(
                "NOP_RESULT command_count=%lu retire_count=%lu final_seqnum=%lu "
                "duplicate_count=%lu dropped_count=%lu total_cycles=%lu "
                "cycles_per_command=%.6f cmd_per_cycle=%.6f decode_cycles=%lu "
                "retire_cycles=%lu\n",
                (unsigned long)metrics.command_count,
                (unsigned long)metrics.retire_count,
                (unsigned long)metrics.final_seqnum,
                (unsigned long)metrics.duplicate_count,
                (unsigned long)metrics.dropped_count,
                (unsigned long)metrics.total_cycles,
                cpc,
                throughput,
                (unsigned long)metrics.decode_cycles,
                (unsigned long)metrics.retire_cycles);
        }
    }

    return 0;
}
