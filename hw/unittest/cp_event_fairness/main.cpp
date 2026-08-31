// 实验9对照测试：测量 WAIT 自旋时三个 SIGNAL 的完成延迟和事件正确性。
#include "vl_simulator.h"
#include "VVX_cp_event_fairness_top.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#ifndef EVENT_WAIT_FAIRNESS
#define EVENT_WAIT_FAIRNESS 1
#endif

static uint64_t timestamp = 0;
static bool trace_en = false;
double sc_time_stamp() { return timestamp; }
bool sim_trace_enabled() { return trace_en; }
void sim_trace_enable(bool enable) { trace_en = enable; }

#define EXPECT(cond, msg) do { if (!(cond)) { \
  std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); } } while (0)

int main(int argc, char** argv) {
  vl_simulator<VVX_cp_event_fairness_top> sim;
  uint64_t tick = 0;
  (void)argc;
  (void)argv;
  sim->start = 0;
  sim->release_x = 0;
  tick = sim.reset(tick);
  sim->start = 1;
  sim->release_x = 0;
  tick = sim.step(tick, 2);
  sim->start = 0;

  std::array<int, 4> retire_cycle = {-1, -1, -1, -1};
  std::array<int, 4> retire_count = {0, 0, 0, 0};
  int retry_count = 0;
  const int release_cycle = 100;
  for (int cycle = 0; cycle < 220; ++cycle) {
    sim->release_x = (cycle == release_cycle);
    sim->eval();
    if (sim->event_retry) ++retry_count;
    for (int q = 0; q < 4; ++q) {
      if ((sim->retire_evt >> q) & 1) {
        ++retire_count[q];
        if (retire_cycle[q] < 0) retire_cycle[q] = cycle;
      }
    }
    // WAIT 在 X 被释放前绝不能退休。
    EXPECT(!(sim->retire_evt & 1) || cycle > release_cycle,
           "EVENT_WAIT 在条件满足前错误退休");
    tick = sim.step(tick, 2);
  }

  for (int q = 0; q < 4; ++q)
    EXPECT(retire_count[q] == 1, "事件命令存在丢失或重复退休");
  EXPECT(retire_cycle[0] > release_cycle, "WAIT 未在释放后正确完成");
  if (EVENT_WAIT_FAIRNESS) {
    EXPECT(retry_count > 0, "公平模式未产生重试");
    for (int q = 1; q < 4; ++q)
      EXPECT(retire_cycle[q] < release_cycle, "SIGNAL 未在 WAIT 期间插入执行");
  } else {
    EXPECT(retry_count == 0, "基线模式不应产生重试");
    for (int q = 1; q < 4; ++q)
      EXPECT(retire_cycle[q] > retire_cycle[0], "基线 SIGNAL 应等待 WAIT 释放资源");
  }

  std::printf("EVENT_FAIRNESS mode=%s poll_count=%u busy_cycles=%u "
              "q0_latency=%d q1_latency=%d q2_latency=%d q3_latency=%d "
              "retry_count=%d lost=0 early_retire=0 duplicate=0 status=PASS\n",
              EVENT_WAIT_FAIRNESS ? "release_backoff" : "baseline_spin",
              sim->poll_count, sim->busy_cycles, retire_cycle[0], retire_cycle[1],
              retire_cycle[2], retire_cycle[3], retry_count);
  return 0;
}
