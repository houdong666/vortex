# 实验五操作与复现命令

本文按实际操作顺序记录实验五所做的工作。所有构建和测试命令均从生成目录 `build/` 执行。

## 步骤 1：配置构建目录

目的：使用 32 位配置和 `/home/houdong/tool` 下的本地工具，并重新生成配置文件。

```bash
cd /home/houdong/vortex
mkdir -p build
cd build
../configure --xlen=32 --tooldir=/home/houdong/tool
```

## 步骤 2：实现 Runtime Command Line Builder

修改：

- 在 `sw/runtime/common/vortex2_internal.h` 增加 64 B 待提交缓存行和已用字节数；
- 在 `sw/runtime/common/device.cpp` 增加命令追加和缓存行 flush；
- 空间不足时自动提交旧缓存行；
- 批处理结束时提交最后一条未满缓存行；
- 同步命令仍立即提交和等待。

查看改动：

```bash
cd /home/houdong/vortex
git diff -- sw/runtime/common/vortex2_internal.h sw/runtime/common/device.cpp
```

## 步骤 3：修正 seqnum 计数语义

将原来“每写一条缓存行加 1”改为“每加入一条命令加 1”。`tail` 仍然每条缓存行增加 64 B。

```bash
git diff -- sw/runtime/common/device.cpp
```

重点检查：

```text
cp_ring_append_()      只推进 cp_tail_
cp_command_append_()   每条命令推进 cp_expected_seqnum_
```

## 步骤 4：编译并运行解包边界测试

新增 20+20+12+12=64 B 的恰好放满场景。

```bash
cd /home/houdong/vortex/build
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_unpack run
```

预期结果：

```text
PASSED — 8 scenarios
```

## 步骤 5：运行 Ring wrap 测试

新增 256 B Ring 的四条缓存行连续读取测试；每条缓存行打包 3 条 DCR，共验证 12 条命令，并检查逻辑地址跨越 Ring 末尾后正确映射回 Ring 起点。

```bash
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_axi_path run
```

预期结果：

```text
PASSED — 4 scenarios
```

## 步骤 6：编译 1000 条 DCR 基准程序

```bash
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_core
```

注意：该 Makefile 的 `run` 目标不转发 `ARGS`，带参数测试要直接调用可执行文件。

## 步骤 7：运行 Baseline

Baseline 让每条 20 B DCR 命令独占一条 64 B 缓存行。

```bash
./hw/unittest/cp_core/cp_core \
  --workload=B1 --commands=1000 --packing=0 --quiet
```

关键结果：

```text
cache_line_count=1000
fetch_bytes=64000
bytes_per_command=64.000000
total_cycles=7011
cmd_per_cycle=0.142633
final_seqnum=1000
```

## 步骤 8：运行 Packed

Packed 让每条缓存行容纳最多三条 20 B DCR 命令。

```bash
./hw/unittest/cp_core/cp_core \
  --workload=B1 --commands=1000 --packing=1 --quiet
```

关键结果：

```text
cache_line_count=334
fetch_bytes=21376
bytes_per_command=21.376000
total_cycles=7011
cmd_per_cycle=0.142633
final_seqnum=1000
```

## 步骤 9：运行相关 CP 回归

```bash
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_dma run
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine run
```

结果：`cp_dma` 的复制和边界测试全部通过，`cp_engine` 的 Smoke 与性能场景通过。

## 步骤 10：编译 Runtime

确认修改后的 `device.cpp` 和头文件能以严格警告配置构建。

```bash
env -u DEBUG make -C sw/runtime/stub clean all
```

结果：成功生成 `build/sw/runtime/libvortex.so`。

## 步骤 11：检查最终改动

```bash
cd /home/houdong/vortex
git diff --check
git status --short
```

## 环境注意事项

当前 Shell 中存在 `DEBUG=release`。它会被部分 RTL Makefile 当成 Verilog 宏值，导致编译错误，因此测试命令统一使用 `env -u DEBUG`。`OBJCACHE=` 用于避免旧缓存对象影响 RTL 单元测试结果。
