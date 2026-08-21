# 实验3 现场补充：DMA 越界与 RingBuffer 冲突判定

## 结论

实验3当前已经能证明 `VX_cp_dma` 的尾拍越界问题，但**不能**直接证明“冲掉命令环”。

原因很简单：现有 `cp_dma` 单元测试只建模 `axi_host` 和 `axi_dev` 两个 AXI 端口，没有实例化 `cp_core` 的命令 ring 取指链路，所以现场里根本没有真实 ringbuffer。

## 已确认的现场

- 目标地址：`payload_addr = 0x3040`
- 测试长度：`1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63, 64, ...`
- 修复前日志中，非 64B 倍数长度会出现：
  - `after_guard_match=0`
  - `last_wstrb=0xffffffffffffffff`
- 修复后日志中同一批长度全部变为：
  - `after_guard_match=1`
  - 尾拍 `WSTRB` 按有效字节数收缩

日志位置：

- `results/exp03/dma_boundary_before.log`
- `results/exp03/dma_boundary_after.log`
- `results/exp03/dma_boundary_before.vcd`
- `results/exp03/dma_boundary_after.vcd`

## 为什么不能直接说“冲掉命令”

`CMD_MEM_WRITE` 的正常路径是：

- 源地址来自 host staging
- 目标地址走 `axi_dev`

而 ringbuffer 走的是 `axi_host`。所以仅凭“DMA 目标数值落进 `[Ring_Base, Ring_Base + 64KB)`”这个条件，不足以推出会覆盖命令。

真正需要同时满足的是：

1. 同一内存域
2. 实际写入区间与 ring 区间相交

判断式可写成：

```text
old_dma_end = dma_dst + round_up(size, 64)
conflict = max(dma_dst, ring_base) < min(old_dma_end, ring_base + 0x10000)
```

## 如何复现

### 复现 DMA 越界本体

```bash
cd /home/houdong/vortex/build
../configure --xlen=32 --tooldir=/home/houdong/vortex/build/tools
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_dma clean run
```

### 对照结果

- 修复前：`results/exp03/dma_boundary_before.log`
- 修复后：`results/exp03/dma_boundary_after.log`

## 备注

如果后面要验证“DMA 真正冲到 ring”，需要把实验搬到 `cp_core` 全链路里，记录：

- `Q_RING_BASE`
- `h_araddr` / `m_araddr`
- `d_awaddr`
- `d_wstrb`

只有这样才能判断 ring 取指地址和 DMA 写地址是否真的落在同一块后端内存上。
