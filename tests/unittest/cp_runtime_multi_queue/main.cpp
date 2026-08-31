#include <vortex2.h>

#include <dlfcn.h>

#include <array>
#include <cstdint>
#include <iostream>

namespace {

int failures = 0;

#define CHECK(cond, text) do {                                               \
    if (!(cond)) {                                                           \
        std::cerr << "FAIL: " << text << std::endl;                         \
        ++failures;                                                          \
    }                                                                        \
} while (0)

vx_queue_info_t queue_info(vx_queue_priority_e priority, uint32_t flags = 0) {
    vx_queue_info_t info = {};
    info.struct_size = sizeof(info);
    info.priority = priority;
    info.flags = flags;
    return info;
}

} // namespace

int main() {
    void* mock = dlopen("libvortex-mockcp.so", RTLD_NOW | RTLD_GLOBAL);
    CHECK(mock != nullptr, "加载Mock-CP后端");
    if (!mock)
        return 1;
    auto control = reinterpret_cast<uint32_t (*)(uint32_t)>(
        dlsym(mock, "mockcp_control"));
    auto seqnum = reinterpret_cast<uint64_t (*)(uint32_t)>(
        dlsym(mock, "mockcp_seqnum"));
    CHECK(control && seqnum, "解析Mock-CP观测接口");

    vx_device_h dev = nullptr;
    CHECK(vx_device_open(0, &dev) == VX_SUCCESS, "打开四队列设备");

    std::array<vx_queue_h, 4> queues = {};
    const std::array<vx_queue_priority_e, 4> priorities = {
        VX_QUEUE_PRIORITY_LOW,
        VX_QUEUE_PRIORITY_NORMAL,
        VX_QUEUE_PRIORITY_HIGH,
        VX_QUEUE_PRIORITY_LOW,
    };
    for (uint32_t i = 0; i < queues.size(); ++i) {
        auto info = queue_info(priorities[i],
                               i == 3 ? VX_QUEUE_PROFILING_ENABLE : 0);
        CHECK(vx_queue_create(dev, &info, &queues[i]) == VX_SUCCESS,
              "软件Queue绑定独立QID");
    }

    CHECK(control(0) == 0x1u, "Q0下传低优先级");
    CHECK(control(1) == 0x5u, "Q1下传普通优先级");
    CHECK(control(2) == 0x9u, "Q2下传高优先级");
    CHECK(control(3) == 0x11u, "Q3下传Profiling位");

    vx_queue_h overflow = nullptr;
    auto normal = queue_info(VX_QUEUE_PRIORITY_NORMAL);
    CHECK(vx_queue_create(dev, &normal, &overflow)
          == VX_ERR_OUT_OF_DEVICE_MEMORY,
          "硬件QID耗尽时拒绝第五个Queue");

    for (uint32_t i = 0; i < queues.size(); ++i) {
        CHECK(vx_enqueue_dcr_write(queues[i], 0x20 + i, 0x100 + i,
                                   0, nullptr, nullptr) == VX_SUCCESS,
              "向独立Ring提交DCR命令");
    }
    for (auto q : queues)
        CHECK(vx_queue_finish(q, VX_TIMEOUT_INFINITE) == VX_SUCCESS,
              "等待各队列完成");

    // Q0在Device初始化时还承担两条COUT元数据清零命令，其他队列只执行一条。
    CHECK(seqnum(0) == 3, "Q0 Seqnum独立推进");
    CHECK(seqnum(1) == 1 && seqnum(2) == 1 && seqnum(3) == 1,
          "Q1到Q3 Seqnum互不串扰");

    std::array<vx_command_t, 2> batch = {};
    for (uint32_t i = 0; i < batch.size(); ++i) {
        batch[i].type = VX_COMMAND_DCR_WRITE;
        batch[i].data.dcr.addr = 0x40 + i;
        batch[i].data.dcr.value = 0x300 + i;
    }
    CHECK(vx_enqueue_commands(queues[2], batch.data(), batch.size(),
                              0, nullptr, nullptr) == VX_SUCCESS,
          "Q2批处理在自己的Ring内Packing");
    CHECK(vx_queue_finish(queues[2], VX_TIMEOUT_INFINITE) == VX_SUCCESS,
          "Q2批处理完成");
    CHECK(seqnum(2) == 3, "Packed命令仍按命令数推进Seqnum");

    CHECK(vx_queue_release(queues[1]) == VX_SUCCESS, "释放Q1");
    queues[1] = nullptr;
    auto high = queue_info(VX_QUEUE_PRIORITY_HIGH);
    CHECK(vx_queue_create(dev, &high, &queues[1]) == VX_SUCCESS,
          "复用已排空QID");
    CHECK(control(1) == 0x9u, "复用时更新硬件优先级");
    CHECK(vx_enqueue_dcr_write(queues[1], 0x31, 0x201,
                               0, nullptr, nullptr) == VX_SUCCESS,
          "复用Ring继续提交");
    CHECK(vx_queue_finish(queues[1], VX_TIMEOUT_INFINITE) == VX_SUCCESS,
          "复用队列完成");
    CHECK(seqnum(1) == 2, "复用QID保持单调Seqnum");

    for (auto q : queues)
        if (q) CHECK(vx_queue_release(q) == VX_SUCCESS, "释放Queue");
    CHECK(vx_device_release(dev) == VX_SUCCESS, "释放Device");
    dlclose(mock);

    if (failures != 0)
        return 1;
    std::cout << "PASS: Runtime四队列绑定、优先级、提交和复用" << std::endl;
    return 0;
}
