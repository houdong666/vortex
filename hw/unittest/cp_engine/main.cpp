// 版权所有 © 2019-2023
// 根据 Apache 许可证 2.0 版授权。

// ============================================================================
// VX_cp_engine 的 Verilator 单元测试。
//
// 向引擎输入构造的 cmd_t，并验证 FSM 路径：
//
//   - 快路径开启时，CMD_NOP：IDLE -> RETIRE
//   - 基线 CMD_NOP / CMD_FENCE：IDLE -> DECODE -> RETIRE
//   - 资源类命令：IDLE -> DECODE -> BID -> WAIT_DONE -> RETIRE
//
// 各操作码的资源分类（cmd:[7:0] 为 header.opcode）：
//
//   0x00 NOP            -> 不竞标，立即退役
//   0x01 MEM_WRITE      -> bid_dma
//   0x02 MEM_READ       -> bid_dma
//   0x03 MEM_COPY       -> bid_dma
//   0x04 DCR_WRITE      -> bid_dcr
//   0x05 DCR_READ       -> bid_dcr
//   0x06 LAUNCH         -> bid_kmu
//   0x07 FENCE          -> 不竞标，立即退役
//   0x08 EVENT_SIGNAL   -> bid EVENT
//   0x09 EVENT_WAIT     -> bid EVENT
//
// 另外检查：
//   - 每退役一条命令，retire_seqnum 严格递增 1
//   - 仅在设置 F_PROFILE 时产生 submit/start/end 性能分析脉冲
//   - state_prio 正确传播到竞标线的优先级字段
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

// cmd_t 是 SystemVerilog packed struct；按语言规则，第一个声明的成员位于
// 最高有效位，因此 cmd_in_packed[287:0] 的布局如下：
//
//   [287:256]  hdr  =  reserved[15:0] | flags[7:0] | opcode[7:0]
//   [255:192]  arg0
//   [191:128]  arg1
//   [127:64]   arg2
//   [63:0]     profile_slot
//
// Verilator 将 288 位信号导出为 uint32_t 的 VlWide<9> 数组，索引 0 是
// 最低有效字。因此 profile_slot 位于 words[0..1]，命令头位于 words[8]。

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
    // [63:0] profile_slot（cmd_t 的最后一个字段）
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

// 驱动输入并计算组合逻辑，采样当前周期输出；随后推进一个时钟边沿，使触发器
// 状态更新在下一次调用时生效。
template <typename T>
static void cycle(vl_simulator<T>& sim, uint64_t& tick) {
    sim->eval();
    tick = sim.step(tick, 2);
}

// 向引擎提交一条命令并运行 FSM 直至完成。`expect_*_bid` 指明 BID 状态下
// 应拉高的资源竞标线；跳过资源的操作码全部为零。同时验证 seqnum 单调性和
// 性能分析脉冲，返回新的期望 seqnum。
template <typename T>
static uint64_t run_one_cmd(vl_simulator<T>& sim, uint64_t& tick,
                            uint8_t opcode, uint8_t flags,
                            bool expect_kmu, bool expect_dma,
                            bool expect_dcr, bool expect_event,
                            uint64_t prior_seqnum) {
    // ----- 前置条件：引擎处于 IDLE -----
    sim->cmd_in_valid = 0;
    set_cmd(sim.operator->(), 0);
    sim->bid_kmu_grant   = 0;
    sim->bid_dma_grant   = 0;
    sim->bid_dcr_grant   = 0;
    sim->bid_event_grant = 0;
    sim->eval();
    EXPECT(sim->cmd_in_ready == 1, "engine not in IDLE before cmd");

    // ----- 周期 1：给出命令并在 IDLE 中锁存 -----
    sim->cmd_in_valid = 1;
    set_cmd(sim.operator->(), opcode, flags, /*arg0=*/0xCAFEBABEull,
            /*arg1=*/0, /*arg2=*/0, /*profile_slot=*/0xDEADBEEFull);
    sim->eval();
    bool prof = (flags & (1u << F_PROFILE_BIT)) != 0;
    bool submit_at_accept = sim->submit_evt != 0;
    cycle(sim, tick);

    sim->cmd_in_valid = 0;
    set_cmd(sim.operator->(), 0);

    // 基线命令在 DECODE 状态报告 submit；带性能分析标记的快路径 NOP 则在
    // 接收命令的周期报告。
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
        // ----- 周期 3：BID -----
        // 仅期望的竞标线拉高。
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

        // 立即授权；FSM 在时钟边沿转入 WAIT_DONE。
        if (expect_kmu)   sim->bid_kmu_grant   = 1;
        if (expect_dma)   sim->bid_dma_grant   = 1;
        if (expect_dcr)   sim->bid_dcr_grant   = 1;
        if (expect_event) sim->bid_event_grant = 1;
        sim->eval();

        // 仅当设置 F_PROFILE 且当前资源获授权时产生 start_evt 脉冲。
        EXPECT((sim->start_evt != 0) == prof, "start_evt mismatch");
        cycle(sim, tick);

        sim->bid_kmu_grant   = 0;
        sim->bid_dma_grant   = 0;
        sim->bid_dcr_grant   = 0;
        sim->bid_event_grant = 0;

        // ----- 周期 4：WAIT_DONE -> 完成脉冲 -> RETIRE -----
        // 引擎等待资源的 done 脉冲后才退役，此处模拟一个周期的完成脉冲。
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

    // ----- RETIRE 周期：retire_evt 拉高，seqnum 仍为旧值 -----
    sim->eval();
    EXPECT(sim->retire_evt == 1, "retire_evt did not fire");
    EXPECT(sim->retire_seqnum == prior_seqnum, "seqnum should not yet have advanced");
    EXPECT((sim->end_evt != 0) == prof, "end_evt mismatch");
    if (prof) {
        EXPECT(sim->profile_slot == 0xDEADBEEFull, "profile_slot did not propagate");
    }
    cycle(sim, tick);

    // RETIRE 结束后 FSM 返回 IDLE，seqnum 已递增。
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
    sim->event_retry_i = 0;
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
    sim->event_retry_i = 0;
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
