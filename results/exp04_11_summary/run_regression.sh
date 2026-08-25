#!/usr/bin/env bash
set -uo pipefail

# 统一从最新源码重建并运行实验4～11；实验10尚未实施，单独记录为DEFERRED。
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
tool_dir="${VORTEX_TOOL_DIR:-/home/houdong/tool}"
build32="${repo_dir}/build"
build64="${repo_dir}/build64"
output_dir="${repo_dir}/results/exp04_11_summary"
log_dir="${output_dir}/logs"
status_file="${output_dir}/regression_status.csv"
failed=0

mkdir -p "${build32}" "${build64}" "${log_dir}"
find "${log_dir}" -maxdepth 1 -type f -name '*.log' -delete
echo "layer,experiment,scenario,status,evidence_or_blocker" >"${status_file}"

record() {
    printf '%s,%s,%s,%s,%s\n' "$1" "$2" "$3" "$4" "$5" >>"${status_file}"
}

run_case() {
    local layer="$1"
    local experiment="$2"
    local scenario="$3"
    local log_name="$4"
    local cwd="$5"
    shift 5
    if (cd "${cwd}" && env -u DEBUG OBJCACHE= "$@") >"${log_dir}/${log_name}.log" 2>&1; then
        if [[ ! -s "${log_dir}/${log_name}.log" ]]; then
            echo "PASS: ${experiment} ${scenario}" >"${log_dir}/${log_name}.log"
        fi
        record "${layer}" "${experiment}" "${scenario}" "PASS" "logs/${log_name}.log"
        echo "PASS ${experiment} ${scenario}"
    else
        record "${layer}" "${experiment}" "${scenario}" "FAIL" "logs/${log_name}.log"
        echo "FAIL ${experiment} ${scenario}" >&2
        failed=1
    fi
}

run_case setup 4-11 configure_xlen32 configure32 "${build32}" \
    ../configure --xlen=32 --tooldir="${tool_dir}"
run_case setup 4-11 configure_xlen64 configure64 "${build64}" \
    ../configure --xlen=64 --tooldir="${tool_dir}"

run_case unit 4 nop_baseline exp04_baseline "${build32}" \
    make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=0
run_case unit 4 nop_fast_path exp04_fastpath "${build32}" \
    make -C hw/unittest/cp_engine clean run NOP_FAST_PATH=1
run_case unit 5 command_unpack exp05_unpack "${build32}" \
    make -C hw/unittest/cp_unpack clean run
run_case unit 6 fetch_depth1 exp06_depth1 "${build32}" \
    make -C hw/unittest/cp_axi_path clean run PREFETCH_DEPTH=1
run_case unit 6 fetch_depth2 exp06_depth2 "${build32}" \
    make -C hw/unittest/cp_axi_path clean run PREFETCH_DEPTH=2
run_case unit 7 priority_arbitration exp07 "${repo_dir}" \
    python3 results/exp07/run_exp07.py
run_case unit 8 aging exp08 "${repo_dir}" \
    python3 results/exp08/run_exp08.py
run_case unit 9 event_wait_fairness exp09 "${repo_dir}" \
    python3 results/exp09/run_exp09.py
run_case integration 11 multi_queue_rtl exp11_rtl "${repo_dir}" \
    python3 results/exp11/run_exp11.py

run_case build 11 runtime_stub runtime_stub "${build64}" \
    make -C sw/runtime/stub -j2
run_case integration 11 runtime_four_queue runtime_multi_queue "${build64}" \
    make -C tests/unittest/cp_runtime_multi_queue clean run

run_case build 4-11 combined_cp_core combined_build "${build32}" \
    make -C hw/unittest/cp_core clean all NUM_QUEUES=1 \
    NOP_FAST_PATH=1 PREFETCH_DEPTH=2 PRIORITY_ARBITRATION=1 \
    ARBITRATION_AGING=1 EVENT_WAIT_FAIRNESS=1
run_case integration 4-11 combined_1000_commands combined_run "${build32}" \
    ./hw/unittest/cp_core/cp_core --workload=B1 --commands=1000 --packing=1 --quiet

run_case model 4-11 simx_demo simx_demo "${build64}" \
    ./ci/blackbox.sh --driver=simx --app=demo --debug=0
run_case rtl 4-11 rtlsim_demo rtlsim_demo "${build64}" \
    ./ci/blackbox.sh --driver=rtlsim --app=demo --debug=0
run_case rtl 4-11 rtlsim_sgemm16 rtlsim_sgemm "${build64}" \
    ./ci/blackbox.sh --driver=rtlsim --app=sgemm --args=-n16 --debug=0

record planning 10 qmd_launch DEFERRED "本阶段尚未实施，不能计入实验完成数"

if command -v xrt-smi >/dev/null 2>&1 \
&& command -v xbutil >/dev/null 2>&1 \
&& [[ -n "${FPGA_BIN_DIR:-}" ]]; then
    run_case xrt 4-11 xrt_demo xrt_demo "${build64}" \
        ./ci/blackbox.sh --driver=xrt --app=demo
    run_case xrt 4-11 xrt_sgemm16 xrt_sgemm "${build64}" \
        ./ci/blackbox.sh --driver=xrt --app=sgemm --args=-n16
else
    record xrt 4-11 full_integration BLOCKED "缺少XRT工具或FPGA_BIN_DIR/xclbin"
fi

if (( failed != 0 )); then
    echo "统一回归存在失败项，请查看 ${status_file}" >&2
    exit 1
fi

echo "统一回归完成：${status_file}"
