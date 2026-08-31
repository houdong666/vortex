#include <callbacks.h>

#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>

namespace {

constexpr uint32_t NUM_QUEUES = 4;
constexpr uint32_t Q_BASE = 0x100;
constexpr uint32_t Q_STRIDE = 0x40;

struct QueueState {
    uint64_t ring_base = 0;
    uint64_t head_addr = 0;
    uint64_t cmpl_addr = 0;
    uint32_t ring_log2 = 16;
    uint32_t control = 0;
    uint32_t tail_lo = 0;
    uint64_t tail = 0;
    uint64_t head = 0;
    uint64_t seqnum = 0;
};

struct MockDevice {
    std::array<QueueState, NUM_QUEUES> queues;
    std::map<uint64_t, uint64_t> host_regions;
    std::mutex mu;
};

MockDevice* g_device = nullptr;

uint32_t command_size(uint8_t opcode) {
    switch (opcode) {
    case 0x06: case 0x0a: case 0x0b: case 0x0c: return 12;
    case 0x07: return 8;
    case 0x04: case 0x05: case 0x08: return 20;
    case 0x01: case 0x02: case 0x03: case 0x09: return 28;
    default: return 4;
    }
}

void publish(QueueState& q) {
    if (q.head_addr)
        std::memcpy(reinterpret_cast<void*>(q.head_addr), &q.head,
                    sizeof(q.head));
    if (q.cmpl_addr)
        std::memcpy(reinterpret_cast<void*>(q.cmpl_addr), &q.seqnum,
                    sizeof(q.seqnum));
}

void consume(QueueState& q) {
    const uint64_t mask = (uint64_t(1) << q.ring_log2) - 1;
    while (q.head < q.tail) {
        auto* line = reinterpret_cast<const uint8_t*>(
            q.ring_base + (q.head & mask));
        uint32_t offset = 0;
        while (offset + 4 <= 64) {
            const uint8_t opcode = line[offset];
            if (opcode == 0)
                break;
            offset += command_size(opcode);
            ++q.seqnum;
        }
        q.head += 64;
    }
    publish(q);
}

bool decode_queue(uint32_t off, uint32_t* qid, uint32_t* local) {
    if (off < Q_BASE || off >= Q_BASE + NUM_QUEUES * Q_STRIDE)
        return false;
    const uint32_t rel = off - Q_BASE;
    *qid = rel / Q_STRIDE;
    *local = rel % Q_STRIDE;
    return true;
}

int dev_open(void** out) {
    auto* d = new MockDevice();
    g_device = d;
    *out = d;
    return 0;
}

int dev_close(void* ctx) {
    auto* d = static_cast<MockDevice*>(ctx);
    g_device = nullptr;
    delete d;
    return 0;
}

int cp_reg_write(void* ctx, uint32_t off, uint32_t value) {
    auto* d = static_cast<MockDevice*>(ctx);
    std::lock_guard<std::mutex> guard(d->mu);
    uint32_t qid = 0, local = 0;
    if (!decode_queue(off, &qid, &local))
        return 0;
    auto& q = d->queues[qid];
    switch (local) {
    case 0x00: q.ring_base = (q.ring_base & 0xffffffff00000000ull) | value; break;
    case 0x04: q.ring_base = (q.ring_base & 0x00000000ffffffffull)
                             | (uint64_t(value) << 32); break;
    case 0x08: q.head_addr = (q.head_addr & 0xffffffff00000000ull) | value; break;
    case 0x0c: q.head_addr = (q.head_addr & 0x00000000ffffffffull)
                             | (uint64_t(value) << 32); break;
    case 0x10: q.cmpl_addr = (q.cmpl_addr & 0xffffffff00000000ull) | value; break;
    case 0x14: q.cmpl_addr = (q.cmpl_addr & 0x00000000ffffffffull)
                             | (uint64_t(value) << 32); break;
    case 0x18: q.ring_log2 = value & 0xffu; break;
    case 0x1c: q.control = value; break;
    case 0x20: q.tail_lo = value; break;
    case 0x24:
        q.tail = (uint64_t(value) << 32) | q.tail_lo;
        consume(q);
        break;
    default: break;
    }
    return 0;
}

int cp_reg_read(void* ctx, uint32_t off, uint32_t* out) {
    auto* d = static_cast<MockDevice*>(ctx);
    std::lock_guard<std::mutex> guard(d->mu);
    if (off == 0x008) {
        *out = (6u << 16) | (16u << 8) | NUM_QUEUES;
        return 0;
    }
    uint32_t qid = 0, local = 0;
    if (!decode_queue(off, &qid, &local)) {
        *out = 0;
        return 0;
    }
    const auto& q = d->queues[qid];
    switch (local) {
    case 0x1c: *out = q.control; break;
    case 0x28: *out = uint32_t(q.seqnum); break;
    case 0x30: *out = 0; break;
    default: *out = 0; break;
    }
    return 0;
}

int host_mem_alloc(void* ctx, uint64_t size, void** host_ptr,
                   uint64_t* cp_addr) {
    auto* d = static_cast<MockDevice*>(ctx);
    const uint64_t aligned = (size + 63) & ~uint64_t(63);
    void* p = std::aligned_alloc(64, aligned);
    if (!p)
        return -1;
    std::memset(p, 0, aligned);
    const uint64_t addr = reinterpret_cast<uint64_t>(p);
    {
        std::lock_guard<std::mutex> guard(d->mu);
        d->host_regions[addr] = aligned;
    }
    *host_ptr = p;
    *cp_addr = addr;
    return 0;
}

int host_mem_free(void* ctx, uint64_t cp_addr) {
    auto* d = static_cast<MockDevice*>(ctx);
    {
        std::lock_guard<std::mutex> guard(d->mu);
        if (d->host_regions.erase(cp_addr) == 0)
            return -1;
    }
    std::free(reinterpret_cast<void*>(cp_addr));
    return 0;
}

} // namespace

extern "C" uint32_t mockcp_control(uint32_t qid) {
    if (!g_device || qid >= NUM_QUEUES)
        return 0xffffffffu;
    std::lock_guard<std::mutex> guard(g_device->mu);
    return g_device->queues[qid].control;
}

extern "C" uint64_t mockcp_seqnum(uint32_t qid) {
    if (!g_device || qid >= NUM_QUEUES)
        return ~uint64_t(0);
    std::lock_guard<std::mutex> guard(g_device->mu);
    return g_device->queues[qid].seqnum;
}

extern "C" int vx_dev_init(callbacks_t* cb) {
    if (!cb)
        return -1;
    *cb = {};
    cb->dev_open = dev_open;
    cb->dev_close = dev_close;
    cb->cp_reg_write = cp_reg_write;
    cb->cp_reg_read = cp_reg_read;
    cb->host_mem_alloc = host_mem_alloc;
    cb->host_mem_free = host_mem_free;
    return 0;
}
