#!/usr/bin/env bash
set -euo pipefail

# 所有构建和整机测试都从配置后的 build 目录执行，避免使用过期生成文件。
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
tool_dir="${VORTEX_TOOL_DIR:-/home/houdong/tool}"
xlen="${VORTEX_XLEN:-64}"
build_dir="${repo_dir}/build${xlen}"

mkdir -p "${build_dir}"
cd "${build_dir}"
../configure --xlen="${xlen}" --tooldir="${tool_dir}"

# 清空 OBJCACHE 可避免本机未安装 ccache 时阻塞 Verilator 编译。
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=0
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=1
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_unpack clean run
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_axi_path clean run PREFETCH_DEPTH=1
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_axi_path clean run PREFETCH_DEPTH=2

cd "${repo_dir}"
python3 results/exp07/run_exp07.py
python3 results/exp08/run_exp08.py
python3 results/exp09/run_exp09.py

cd "${build_dir}"
../configure --xlen="${xlen}" --tooldir="${tool_dir}"
env -u DEBUG OBJCACHE= make -C hw/unittest/cp_core clean all \
    NOP_FAST_PATH=1 PREFETCH_DEPTH=2 PRIORITY_ARBITRATION=1 \
    ARBITRATION_AGING=1 EVENT_WAIT_FAIRNESS=1
./hw/unittest/cp_core/cp_core --workload=B1 --commands=1000 --packing=1 --quiet

# rtlsim 依赖完整子模块；失败时保留真实错误，不把环境阻塞伪装成通过。
env -u DEBUG CCACHE_DISABLE=1 OBJCACHE= ./ci/blackbox.sh --driver=rtlsim --app=demo
env -u DEBUG CCACHE_DISABLE=1 OBJCACHE= ./ci/blackbox.sh --driver=rtlsim --app=sgemm --args="-n16"

# XRT 必须同时具备运行时、设备工具和已经生成的平台镜像。
command -v xrt-smi >/dev/null
command -v xbutil >/dev/null
test -n "${FPGA_BIN_DIR:-}"
./ci/blackbox.sh --driver=xrt --app=demo
./ci/blackbox.sh --driver=xrt --app=sgemm --args="-n16"
