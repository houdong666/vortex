# 实验0 基线总结

日期：2026-08-19

## 基线信息

- Vortex 版本：3.0
- 实测源码 commit：`71c687a46155bd3fadc6bb4da2333e3fde47e789`
- 实验指导书参考快照：`d76b7f24e658867ab57e3942d7c648c3e6af072d`
- 配置命令：`../configure --xlen=32 --tooldir=$HOME/tools`
- 构建目录：`build/`
- 测试命令格式：`env CCACHE_DISABLE=1 VCD_FILE=<repo>/results/baseline/<test>.vcd make -C hw/unittest/<test> DEBUG=0 run`

## 配置

- XLEN：32
- NUM_CORES：1
- NUM_WARPS：4
- NUM_THREADS：4
- I-cache：开启
- D-cache：开启
- L2 cache：关闭
- L3 cache：关闭

## 工具链

- Verilator：5.046 2026-02-28 rev v5.046-55-g1264184fb
- GCC：Ubuntu 11.4.0-1ubuntu1~22.04.3
- G++：Ubuntu 11.4.0-1ubuntu1~22.04.3

## 测试结果

`cp_unpack` 是组合逻辑测试，不会推进 `vl_simulator::step()`，因此无法从 VCD 得到时钟周期数。
其余测试的完整时钟周期按最终 VCD 时间戳换算，公式为 `(last_timestamp + 1) / 2`。

| 测试 | 结果 | 完整时钟周期 | 墙钟时间 (s) | 日志 |
|---|---:|---:|---:|---|
| cp_unpack | PASS | N/A | 1.48 | `cp_unpack.log` |
| cp_engine | PASS | 60 | 1.47 | `cp_engine.log` |
| cp_arbiter | PASS | 26 | 1.46 | `cp_arbiter.log` |
| cp_dma | PASS | 21 | 1.46 | `cp_dma.log` |
| cp_dcr_proxy | PASS | 18 | 1.45 | `cp_dcr_proxy.log` |
| cp_launch | PASS | 28 | 1.46 | `cp_launch.log` |
| cp_axil_regfile | PASS | 99 | 1.49 | `cp_axil_regfile.log` |
| cp_axi_path | PASS | 26 | 1.52 | `cp_axi_path.log` |
| cp_core | PASS | 34 | 3.24 | `cp_core.log` |

## 遇到的问题

1. 第一次调试构建失败，是因为环境变量里带了 `DEBUG=release`，导致实际传入 `-DVX_DBG_DEBUG_LEVEL=release`。在 Verilator 5.046 下，`release` 会被当作 SystemVerilog 保留关键字，进而在 `VX_trace_pkg.sv` 中触发语法错误。基线运行时我改用 `DEBUG=0` 做带波形的运行，并用 `env -u DEBUG` 跑非波形测试。
2. 第一次非调试构建失败，是因为 `ccache` 试图创建 `/run/user/1000/ccache-tmp`，但当前环境对此路径是只读的。基线运行时改用 `CCACHE_DISABLE=1`，也符合仓库里避免陈旧缓存干扰仿真的建议。
3. `cp_unpack` 不会产出有效的 VCD 时间戳，因为它直接验证组合 unpack 行为，没有调用 `step()`。所以它的 PASS/FAIL 和墙钟时间都记录了，但周期数标为 `N/A`。
4. 实验0正文里的测试清单写了 8 个 CP 单测，但更前面的单元测试清单里还包含 `cp_axi_path`。本次 baseline 额外把 `cp_axi_path` 也纳入了记录。

## 复现方式

在仓库根目录下执行：

```bash
cd build
../configure --xlen=32 --tooldir=$HOME/tools

for test in cp_unpack cp_engine cp_arbiter cp_dma cp_dcr_proxy cp_launch cp_axil_regfile cp_axi_path cp_core; do
  log="../results/baseline/${test}.log"
  vcd="$(pwd)/../results/baseline/${test}.vcd"
  echo "== ${test} ==" | tee "${log}"
  env -u DEBUG CCACHE_DISABLE=1 make -C "hw/unittest/${test}" clean >> "${log}" 2>&1
  /usr/bin/time -f 'ELAPSED_SECONDS=%e' env CCACHE_DISABLE=1 VCD_FILE="${vcd}" make -C "hw/unittest/${test}" DEBUG=0 run >> "${log}" 2>&1
  echo "EXIT_STATUS=$?" >> "${log}"
done
```

## 基线结论

实验0列出的 CP 单元测试在本次实测 commit 上全部通过，且尚未开始任何 RTL 优化。
