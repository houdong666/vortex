// 版权所有 © 2019-2023
// 根据 Apache 许可证 2.0 版授权。

// VX_cp_dma 的 Verilator 单元测试。

#include "vl_simulator.h"
#include "VVX_cp_dma_top.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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

// cmd_t 打包规则：opcode 位于最高有效字（索引 8），arg0/1/2 分别位于
// 字 [6..7]、[4..5]、[2..3]。
static void pack_cmd(uint32_t out_words[9],
                     uint8_t opcode, uint8_t flags,
                     uint64_t arg0, uint64_t arg1, uint64_t arg2) {
    for (int i = 0; i < 9; ++i) out_words[i] = 0;
    out_words[2] = (uint32_t)(arg2 & 0xffffffffu);
    out_words[3] = (uint32_t)(arg2 >> 32);
    out_words[4] = (uint32_t)(arg1 & 0xffffffffu);
    out_words[5] = (uint32_t)(arg1 >> 32);
    out_words[6] = (uint32_t)(arg0 & 0xffffffffu);
    out_words[7] = (uint32_t)(arg0 >> 32);
    out_words[8] = (uint32_t)opcode | ((uint32_t)flags << 8);
}

struct MemoryImage {
    static constexpr uint64_t MEM_BASE = 0x1000;
    static constexpr int      MEM_SIZE = 64 * 1024;

    std::array<uint8_t, MEM_SIZE> mem{};

    void fill(uint8_t value) {
        mem.fill(value);
    }

    void write_bytes(uint64_t addr, const uint8_t* src, size_t size) {
        for (size_t i = 0; i < size; ++i) {
            int64_t a = (int64_t)addr - (int64_t)MEM_BASE + (int64_t)i;
            if (a >= 0 && a < MEM_SIZE) mem[(size_t)a] = src[i];
        }
    }

    void read_cl(uint64_t addr, uint32_t* dst) const {
        for (int w = 0; w < 16; ++w) {
            uint32_t value = 0;
            for (int b = 0; b < 4; ++b) {
                int64_t a = (int64_t)addr - (int64_t)MEM_BASE + w * 4 + b;
                if (a >= 0 && a < MEM_SIZE)
                    value |= (uint32_t)mem[(size_t)a] << (8 * b);
            }
            dst[w] = value;
        }
    }

    void write_cl(uint64_t addr, const uint32_t* src, uint64_t wstrb) {
        for (int lane = 0; lane < 64; ++lane) {
            if (((wstrb >> lane) & 1ull) == 0) continue;
            int64_t a = (int64_t)addr - (int64_t)MEM_BASE + lane;
            if (a < 0 || a >= MEM_SIZE) continue;
            const uint32_t word = src[lane / 4];
            mem[(size_t)a] = (uint8_t)(word >> (8 * (lane % 4)));
        }
    }

    bool region_equals(uint64_t addr, const uint8_t* expected,
                       size_t size) const {
        for (size_t i = 0; i < size; ++i) {
            int64_t a = (int64_t)addr - (int64_t)MEM_BASE + (int64_t)i;
            uint8_t actual = (a >= 0 && a < MEM_SIZE) ? mem[(size_t)a] : 0;
            if (actual != expected[i]) return false;
        }
        return true;
    }

    bool region_is(uint64_t addr, size_t size, uint8_t expected) const {
        for (size_t i = 0; i < size; ++i) {
            int64_t a = (int64_t)addr - (int64_t)MEM_BASE + (int64_t)i;
            uint8_t actual = (a >= 0 && a < MEM_SIZE) ? mem[(size_t)a] : 0;
            if (actual != expected) return false;
        }
        return true;
    }

    int compare_cl(uint64_t addr_a, uint64_t addr_b) const {
        for (int i = 0; i < 64; ++i) {
            int64_t aa = (int64_t)addr_a - (int64_t)MEM_BASE + i;
            int64_t ab = (int64_t)addr_b - (int64_t)MEM_BASE + i;
            uint8_t va = (aa >= 0 && aa < MEM_SIZE) ? mem[(size_t)aa] : 0;
            uint8_t vb = (ab >= 0 && ab < MEM_SIZE) ? mem[(size_t)ab] : 0;
            if (va != vb) return i;
        }
        return -1;
    }
};

struct HostAxiMemory : MemoryImage {
    bool     r_inflight = false;
    uint64_t r_addr = 0;
    uint32_t r_beats_left = 0;
    uint8_t  r_id = 0;

    template <typename T>
    void comb_drive(T* top) {
        top->h_awready = 0;
        top->h_wready = 0;
        top->h_bvalid = 0;
        top->h_bid = 0;
        top->h_bresp = 0;

        top->h_arready = !r_inflight;
        top->h_rvalid = r_inflight;
        top->h_rid = r_id;
        top->h_rlast = r_inflight && r_beats_left == 1;
        top->h_rresp = 0;
        for (int i = 0; i < 16; ++i) top->h_rdata[i] = 0;
        if (r_inflight) read_cl(r_addr, top->h_rdata);
    }

    template <typename T>
    void posedge_update(T* top) {
        if (top->h_arvalid && top->h_arready) {
            r_inflight = true;
            r_addr = top->h_araddr;
            r_beats_left = (uint32_t)top->h_arlen + 1;
            r_id = top->h_arid;
        } else if (r_inflight && top->h_rvalid && top->h_rready) {
            if (r_beats_left == 1) {
                r_inflight = false;
            } else {
                r_addr += 64;
                --r_beats_left;
            }
        }
    }
};

struct DeviceAxiMemory : MemoryImage {
    bool     r_inflight = false;
    uint64_t r_addr = 0;
    uint32_t r_beats_left = 0;
    uint8_t  r_id = 0;

    bool     aw_inflight = false;
    uint64_t aw_addr = 0;
    uint32_t w_beats_left = 0;
    uint8_t  aw_id = 0;
    bool     b_pending = false;
    uint8_t  b_id = 0;

    uint64_t last_wstrb = 0;
    uint64_t write_beats = 0;

    void reset_observation() {
        last_wstrb = 0;
        write_beats = 0;
    }

    template <typename T>
    void comb_drive(T* top) {
        top->d_arready = !r_inflight;
        top->d_rvalid = r_inflight;
        top->d_rid = r_id;
        top->d_rlast = r_inflight && r_beats_left == 1;
        top->d_rresp = 0;
        for (int i = 0; i < 16; ++i) top->d_rdata[i] = 0;
        if (r_inflight) read_cl(r_addr, top->d_rdata);

        top->d_awready = !aw_inflight && !b_pending;
        top->d_wready = aw_inflight && !b_pending;
        top->d_bvalid = b_pending;
        top->d_bid = b_id;
        top->d_bresp = 0;
    }

    template <typename T>
    void posedge_update(T* top) {
        if (top->d_arvalid && top->d_arready) {
            r_inflight = true;
            r_addr = top->d_araddr;
            r_beats_left = (uint32_t)top->d_arlen + 1;
            r_id = top->d_arid;
        } else if (r_inflight && top->d_rvalid && top->d_rready) {
            if (r_beats_left == 1) {
                r_inflight = false;
            } else {
                r_addr += 64;
                --r_beats_left;
            }
        }

        if (top->d_awvalid && top->d_awready) {
            aw_inflight = true;
            aw_addr = top->d_awaddr;
            w_beats_left = (uint32_t)top->d_awlen + 1;
            aw_id = top->d_awid;
        }
        if (aw_inflight && top->d_wvalid && top->d_wready) {
            write_cl(aw_addr, top->d_wdata, (uint64_t)top->d_wstrb);
            last_wstrb = (uint64_t)top->d_wstrb;
            ++write_beats;
            if (w_beats_left == 1) {
                EXPECT(top->d_wlast, "AXI write burst ended without WLAST");
                aw_inflight = false;
                b_pending = true;
                b_id = aw_id;
            } else {
                EXPECT(!top->d_wlast, "AXI write asserted WLAST early");
                aw_addr += 64;
                --w_beats_left;
            }
        }
        if (b_pending && top->d_bvalid && top->d_bready)
            b_pending = false;
    }
};

template <typename T>
static void cycle(vl_simulator<T>& sim, HostAxiMemory& host,
                  DeviceAxiMemory& device, uint64_t& tick) {
    auto* top = sim.operator->();
    host.comb_drive(top);
    device.comb_drive(top);
    top->eval();
    host.comb_drive(top);
    device.comb_drive(top);
    top->eval();
    host.posedge_update(top);
    device.posedge_update(top);
    tick = sim.step(tick, 2);
    host.comb_drive(top);
    device.comb_drive(top);
    top->eval();
}

template <typename T>
static void drain_to_idle(vl_simulator<T>& sim, HostAxiMemory& host,
                          DeviceAxiMemory& device, uint64_t& tick) {
    sim->grant = 0;
    for (int i = 0; i < 3; ++i) cycle(sim, host, device, tick);
}

template <typename T>
static void run_command(vl_simulator<T>& sim, HostAxiMemory& host,
                        DeviceAxiMemory& device, uint64_t& tick,
                        uint8_t opcode, uint64_t dst, uint64_t src,
                        uint64_t size) {
    drain_to_idle(sim, host, device, tick);

    uint32_t command[9];
    pack_cmd(command, opcode, 0, dst, src, size);
    for (int i = 0; i < 9; ++i) sim->cmd_packed[i] = command[i];

    sim->grant = 1;
    bool started = false;
    for (int i = 0; i < 8 && !started; ++i) {
        cycle(sim, host, device, tick);
        started = sim->h_arvalid || sim->d_arvalid;
    }
    sim->grant = 0;
    EXPECT(started, "DMA never asserted ARVALID");

    bool completed = false;
    for (int i = 0; i < 2000 && !completed; ++i) {
        cycle(sim, host, device, tick);
        completed = sim->done;
    }
    EXPECT(completed, "DMA did not signal done within 2000 cycles");
}

static std::vector<uint8_t> make_payload(uint64_t size) {
    std::vector<uint8_t> payload((size_t)size);
    for (uint64_t i = 0; i < size; ++i)
        payload[(size_t)i] = (uint8_t)(0x31u + ((i * 13u + size) & 0xffu));
    return payload;
}

template <typename T>
static bool run_boundary_case(vl_simulator<T>& sim, HostAxiMemory& host,
                              DeviceAxiMemory& device, uint64_t& tick,
                              uint64_t size) {
    constexpr uint64_t GUARD = 100;
    constexpr uint64_t payload_addr = MemoryImage::MEM_BASE + 0x2000 + 64;
    const auto payload = make_payload(size);

    host.fill(0);
    device.fill(0xAA);
    host.write_bytes(payload_addr, payload.data(), payload.size());
    device.reset_observation();

    run_command(sim, host, device, tick, /*CMD_MEM_WRITE=*/0x01,
                payload_addr, payload_addr, size);

    const bool before_guard_match =
        device.region_is(payload_addr - GUARD, GUARD, 0xAA);
    const bool payload_match =
        device.region_equals(payload_addr, payload.data(), payload.size());
    const bool after_guard_match =
        device.region_is(payload_addr + size, GUARD, 0xAA);

    std::printf(
        "DMA_RESULT size=%llu payload_match=%d before_guard_match=%d "
        "after_guard_match=%d last_wstrb=0x%016llx write_beats=%llu\n",
        (unsigned long long)size,
        payload_match ? 1 : 0,
        before_guard_match ? 1 : 0,
        after_guard_match ? 1 : 0,
        (unsigned long long)device.last_wstrb,
        (unsigned long long)device.write_beats);

    return payload_match && before_guard_match && after_guard_match;
}

template <typename T>
static void run_copy(vl_simulator<T>& sim, HostAxiMemory& host,
                     DeviceAxiMemory& device, uint64_t& tick,
                     uint64_t src, uint64_t dst, const uint8_t* pattern) {
    device.fill(0);
    device.write_bytes(src, pattern, 64);
    run_command(sim, host, device, tick, /*CMD_MEM_COPY=*/0x03,
                dst, src, 64);
    EXPECT(device.compare_cl(src, dst) < 0,
           "MEM_COPY destination does not match source");
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    vl_simulator<VVX_cp_dma_top> sim;
    uint64_t tick = 0;
    HostAxiMemory host;
    DeviceAxiMemory device;

    sim->grant = 0;
    for (int i = 0; i < 9; ++i) sim->cmd_packed[i] = 0;
    tick = sim.reset(tick);

    // 保留原有的对齐设备到设备拷贝冒烟测试覆盖。
    {
        uint8_t pattern[64];
        for (int i = 0; i < 64; ++i) pattern[i] = (uint8_t)(0xA0 + i);
        run_copy(sim, host, device, tick, 0x1000, 0x1100, pattern);
    }
    {
        uint8_t pattern[64];
        for (int i = 0; i < 64; ++i) pattern[i] = (uint8_t)(0x5A ^ (i << 1));
        run_copy(sim, host, device, tick, 0x1200, 0x1300, pattern);
    }

    const std::array<uint64_t, 23> sizes = {
        1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63, 64,
        65, 66, 127, 128, 129, 255, 256, 257, 4095, 4096, 4097
    };
    bool all_pass = true;
    for (uint64_t size : sizes)
        all_pass &= run_boundary_case(sim, host, device, tick, size);

    if (!all_pass) {
        std::fprintf(stderr, "DMA boundary regression FAILED\n");
        return 1;
    }

    std::printf("PASSED — 2 copy scenarios + %zu boundary scenarios\n",
                sizes.size());
    return 0;
}
