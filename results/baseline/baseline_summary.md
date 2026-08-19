# Experiment 0 Baseline Summary

Date: 2026-08-19

## Baseline Identity

- Vortex version: 3.0
- Source commit tested: `71c687a46155bd3fadc6bb4da2333e3fde47e789`
- Reference snapshot from lab guide: `d76b7f24e658867ab57e3942d7c648c3e6af072d`
- Configure command: `../configure --xlen=32 --tooldir=$HOME/tools`
- Build directory: `build/`
- Test command pattern: `env CCACHE_DISABLE=1 VCD_FILE=<repo>/results/baseline/<test>.vcd make -C hw/unittest/<test> DEBUG=0 run`

## Configuration

- XLEN: 32
- NUM_CORES: 1
- NUM_WARPS: 4
- NUM_THREADS: 4
- I-cache: enabled
- D-cache: enabled
- L2 cache: disabled
- L3 cache: disabled

## Toolchain

- Verilator: 5.046 2026-02-28 rev v5.046-55-g1264184fb
- GCC: Ubuntu 11.4.0-1ubuntu1~22.04.3
- G++: Ubuntu 11.4.0-1ubuntu1~22.04.3

## Test Results

`cp_unpack` is a combinational test and does not advance `vl_simulator::step()`, so no clock-cycle count is available from the VCD.
For the other tests, full clock cycles are derived from the final VCD timestamp as `(last_timestamp + 1) / 2`.

| Test | Status | Full clock cycles | Wall time (s) | Log |
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

## Issues Encountered

1. The first debug build failed because the environment supplied `DEBUG=release`, producing `-DVX_DBG_DEBUG_LEVEL=release`. With Verilator 5.046, `release` is parsed as a reserved SystemVerilog keyword inside `VX_trace_pkg.sv`, causing syntax errors. The baseline run used `DEBUG=0` for trace-enabled runs and `env -u DEBUG` for non-trace runs.
2. The first non-debug build failed because `ccache` attempted to create `/run/user/1000/ccache-tmp`, but that path is read-only in this execution environment. The baseline run used `CCACHE_DISABLE=1`, which also matches the repository guidance for avoiding stale ccache artifacts during simulation debugging.
3. `cp_unpack` does not produce VCD timestamps because the test directly evaluates combinational unpack behavior without calling `step()`. Its PASS/FAIL and wall time are recorded, but cycle count is marked N/A.
4. The lab guide's Experiment 0 deliverable list names eight CP tests, while the earlier CP unit-test inventory also includes `cp_axi_path`. This baseline includes `cp_axi_path` as well.

## Reproduction

From the repository root:

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

## Baseline Status

All CP unit tests listed for Experiment 0 passed on the tested commit. No RTL optimization has been started.
