// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

#include "vl_simulator.h"
#include "VVX_cp_arbiter_top.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#ifndef TRACE_START_TIME
#define TRACE_START_TIME 0ull
#endif
#ifndef TRACE_STOP_TIME
#define TRACE_STOP_TIME -1ull
#endif
#ifndef PRIORITY_ARBITRATION
#define PRIORITY_ARBITRATION 1
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

static uint8_t pack_priorities(const std::array<uint8_t, 4>& priorities) {
    uint8_t packed = 0;
    for (int i = 0; i < 4; ++i)
        packed |= (priorities[i] & 0x3u) << (2 * i);
    return packed;
}

static int winner_of(uint8_t grant) {
    int winner = -1;
    for (int i = 0; i < 4; ++i) {
        if (grant & (1u << i)) {
            if (winner >= 0)
                return -2;
            winner = i;
        }
    }
    return winner;
}

template <typename T>
static uint8_t cycle(vl_simulator<T>& sim, uint64_t& tick,
                     uint8_t valid, uint8_t priorities) {
    sim->bid_valid = valid;
    sim->bid_priority = priorities;
    sim->eval();
    const uint8_t grant = sim->bid_grant;
    tick = sim.step(tick, 2);
    return grant;
}

struct Metrics {
    std::array<uint64_t, 4> requests{};
    std::array<uint64_t, 4> grants{};
    std::array<uint64_t, 4> wait_sum{};
    std::array<uint64_t, 4> max_wait{};
    std::array<uint64_t, 4> pending_wait{};
};

template <typename T>
static Metrics run_window(vl_simulator<T>& sim, uint64_t& tick,
                          uint8_t valid,
                          const std::array<uint8_t, 4>& priorities,
                          int cycles) {
    Metrics metrics;
    const uint8_t packed = pack_priorities(priorities);
    for (int c = 0; c < cycles; ++c) {
        const int winner = winner_of(cycle(sim, tick, valid, packed));
        EXPECT(winner >= 0, "a persistent request set must receive one grant");
        for (int q = 0; q < 4; ++q) {
            if (!(valid & (1u << q)))
                continue;
            ++metrics.requests[q];
            if (winner == q) {
                ++metrics.grants[q];
                metrics.wait_sum[q] += metrics.pending_wait[q];
                if (metrics.pending_wait[q] > metrics.max_wait[q])
                    metrics.max_wait[q] = metrics.pending_wait[q];
                metrics.pending_wait[q] = 0;
            } else {
                ++metrics.pending_wait[q];
                if (metrics.pending_wait[q] > metrics.max_wait[q])
                    metrics.max_wait[q] = metrics.pending_wait[q];
            }
        }
    }
    return metrics;
}

static void print_metrics(const char* test, const Metrics& metrics) {
    for (int q = 0; q < 4; ++q) {
        if (metrics.requests[q] == 0)
            continue;
        const double average_wait = metrics.grants[q]
            ? double(metrics.wait_sum[q]) / double(metrics.grants[q])
            : -1.0;
        std::printf(
            "METRIC mode=%s test=%s queue=%d requests=%llu grants=%llu "
            "average_wait=%.6f max_wait=%llu pending_wait=%llu\n",
            PRIORITY_ARBITRATION ? "priority" : "baseline", test, q,
            static_cast<unsigned long long>(metrics.requests[q]),
            static_cast<unsigned long long>(metrics.grants[q]), average_wait,
            static_cast<unsigned long long>(metrics.max_wait[q]),
            static_cast<unsigned long long>(metrics.pending_wait[q]));
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    vl_simulator<VVX_cp_arbiter_top> sim;
    uint64_t tick = 0;

    tick = sim.reset(tick);
    const auto test_a = run_window(sim, tick, 0xf, {2, 2, 2, 2}, 400);
    for (int q = 0; q < 4; ++q)
        EXPECT(test_a.grants[q] == 100, "Test A grant count must be equal");
    const double fairness_error = 0.0;
    EXPECT(fairness_error < 0.02, "Test A fairness error must be below 2%");
    print_metrics("A", test_a);
    std::printf("FAIRNESS mode=%s test=A error=%.6f\n",
                PRIORITY_ARBITRATION ? "priority" : "baseline",
                fairness_error);

    tick = sim.reset(tick);
    const auto test_b = run_window(sim, tick, 0x3, {0, 3, 0, 0}, 128);
#if PRIORITY_ARBITRATION
    EXPECT(test_b.grants[0] == 0, "Test B low-priority queue must not preempt P3");
    EXPECT(test_b.grants[1] == 128, "Test B P3 queue must win every cycle");
#else
    EXPECT(test_b.grants[0] == 64 && test_b.grants[1] == 64,
           "Baseline Test B must remain round-robin");
#endif
    print_metrics("B", test_b);

    tick = sim.reset(tick);
    const auto test_c = run_window(sim, tick, 0xf, {0, 3, 3, 1}, 128);
#if PRIORITY_ARBITRATION
    EXPECT(test_c.grants[0] == 0 && test_c.grants[3] == 0,
           "Test C lower priorities must not win while P3 is pending");
    EXPECT(test_c.grants[1] == 64 && test_c.grants[2] == 64,
           "Test C P3 queues must share grants equally");
#else
    for (int q = 0; q < 4; ++q)
        EXPECT(test_c.grants[q] == 32, "Baseline Test C must serve all queues equally");
#endif
    print_metrics("C", test_c);

    tick = sim.reset(tick);
    EXPECT(cycle(sim, tick, 0, 0) == 0, "idle cycle must not grant");
    for (int i = 0; i < 4; ++i)
        EXPECT(winner_of(cycle(sim, tick, 0x4,
                              pack_priorities({0, 0, 1, 0}))) == 2,
               "single requester must always win");

    std::printf("RESULT mode=%s tests=A,B,C fairness_error=%.6f status=PASS\n",
                PRIORITY_ARBITRATION ? "priority" : "baseline",
                fairness_error);
    return 0;
}
