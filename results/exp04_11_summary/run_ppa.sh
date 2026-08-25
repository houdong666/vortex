#!/usr/bin/env bash
set -euo pipefail

# 实验9比较同一四队列CP的公平开关，实验11比较同配置下一队列与四队列。
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
build_dir="${VORTEX_BUILD_DIR:-${repo_dir}/build}"
sv2v_bin="${SV2V_BIN:-/home/houdong/tool/sv2v/bin/sv2v}"
yosys_bin="${YOSYS_BIN:-/home/houdong/tool/yosys-0.40/bin/yosys}"
abc_bin="$(dirname "${yosys_bin}")/yosys-abc"
liberty_file="${repo_dir}/hw/syn/libs/NangateOpenCellLibrary_typical.lib"
output_dir="${repo_dir}/results/exp04_11_summary/ppa"
exp09_metrics="${repo_dir}/results/exp09/ppa_metrics.csv"
exp11_metrics="${repo_dir}/results/exp11/ppa_metrics.csv"
combined_metrics="${repo_dir}/results/exp04_11_summary/combined_ppa_metrics.csv"
temp_dir="$(mktemp -d /tmp/vortex-exp09-11-ppa.XXXXXX)"
flat_verilog="${temp_dir}/cp_core_flat.v"

trap 'rm -rf "${temp_dir}"' EXIT

test -x "${sv2v_bin}"
test -x "${yosys_bin}"
test -x "${abc_bin}"
test -f "${build_dir}/hw/VX_config.vh"
mkdir -p "${output_dir}"

yosys_version="$(${yosys_bin} -V | awk '{print $2}')"
abc_version="$(${abc_bin} -c version 2>&1 | awk '/UC Berkeley/ {print $4; exit}')"
oldest_version="$(printf '%s\n' 0.40 "${yosys_version}" | sort -V | head -n 1)"
if [[ "${oldest_version}" != "0.40" ]]; then
    echo "错误：完整CP综合要求Yosys不低于0.40，当前为${yosys_version}" >&2
    exit 1
fi

"${sv2v_bin}" \
    -DSYNTHESIS -DVX_CFG_XLEN=32 -DVX_CFG_XLEN_32 \
    -I"${build_dir}/hw" -I"${build_dir}/sw" \
    -I"${repo_dir}/hw/rtl" -I"${repo_dir}/hw/rtl/libs" \
    -I"${repo_dir}/hw/rtl/interfaces" -I"${repo_dir}/hw/rtl/mem" \
    -I"${repo_dir}/hw/rtl/core" -I"${repo_dir}/hw/rtl/cp" \
    -y"${repo_dir}/hw/rtl/libs" -y"${repo_dir}/hw/rtl/interfaces" \
    -y"${repo_dir}/hw/rtl/mem" -y"${repo_dir}/hw/rtl/core" \
    -y"${repo_dir}/hw/rtl/cp" \
    "${repo_dir}/hw/rtl/VX_gpu_pkg.sv" \
    "${repo_dir}/hw/rtl/VX_trace_pkg.sv" \
    "${repo_dir}/hw/rtl/cp/VX_cp_pkg.sv" \
    "${repo_dir}/hw/unittest/cp_core/VX_cp_core_top.sv" \
    --top=VX_cp_core_top --write="${flat_verilog}"

run_scenario() {
    local scenario="$1"
    local num_queues="$2"
    local nop_fast_path="$3"
    local prefetch_depth="$4"
    local priority="$5"
    local aging="$6"
    local event_fairness="$7"
    local scenario_dir="${output_dir}/${scenario}"
    local params="-set NUM_QUEUES ${num_queues} -set ENABLE_NOP_FAST_PATH ${nop_fast_path} -set PREFETCH_DEPTH ${prefetch_depth} -set ENABLE_PRIORITY_ARBITRATION ${priority} -set ENABLE_ARBITRATION_AGING ${aging} -set ENABLE_EVENT_WAIT_FAIRNESS ${event_fairness}"

    mkdir -p "${scenario_dir}"
    if [[ "${REUSE_PPA:-0}" != "1" || ! -s "${scenario_dir}/fpga_stat.rpt" ]]; then
        "${yosys_bin}" -q -p \
            "read_verilog -defer ${flat_verilog}; chparam ${params} VX_cp_core_top; synth_xilinx -flatten -family xc7 -top VX_cp_core_top; tee -o ${scenario_dir}/fpga_stat.rpt stat -tech xilinx; check" \
            >"${scenario_dir}/fpga_yosys.log" 2>&1
    fi
    # 默认从最新源码重跑；仅调试提取脚本时可显式设置REUSE_PPA=1复用报告。
    if [[ "${REUSE_PPA:-0}" != "1" || ! -s "${scenario_dir}/asic_stat.rpt" ]]; then
        "${yosys_bin}" -q -p \
            "read_liberty -lib ${liberty_file}; read_verilog -defer ${flat_verilog}; chparam ${params} VX_cp_core_top; hierarchy -check -top VX_cp_core_top; proc; opt; fsm; opt; memory; opt; memory_map; opt; alumacc; wreduce; share; opt; techmap; opt; dfflibmap -liberty ${liberty_file}; abc -markgroups -D 2.5 -liberty ${liberty_file}; tee -o ${scenario_dir}/asic_stat.rpt stat -liberty ${liberty_file} -top VX_cp_core_top -width -tech cmos; check" \
            >"${scenario_dir}/asic_yosys.log" 2>&1
    fi
}

run_scenario q4_baseline 4 0 1 0 0 0
run_scenario q4_all_enabled 4 1 2 1 1 1
run_scenario q4_event_off 4 0 1 1 1 0
run_scenario q1_full 1 0 1 1 1 1
run_scenario q4_full 4 0 1 1 1 1

extract_fpga() {
    local scenario="$1"
    local pattern="$2"
    awk -v pattern="${pattern}" \
        '$1 == pattern {value=$NF} /Estimated number of LCs:/ && pattern == "LC" {value=$NF} END {print value+0}' \
        "${output_dir}/${scenario}/fpga_stat.rpt"
}

extract_area() {
    awk '/Chip area for top module/ {value=$NF} END {print value}' \
        "${output_dir}/$1/asic_stat.rpt"
}

percent() {
    awk -v base="$1" -v value="$2" 'BEGIN {printf "%.2f", (value-base)*100/base}'
}

q4_off_lcs="$(extract_fpga q4_event_off LC)"
q4_off_fdre="$(extract_fpga q4_event_off FDRE)"
q4_off_area="$(extract_area q4_event_off)"
q1_lcs="$(extract_fpga q1_full LC)"
q1_fdre="$(extract_fpga q1_full FDRE)"
q1_area="$(extract_area q1_full)"
q4_lcs="$(extract_fpga q4_full LC)"
q4_fdre="$(extract_fpga q4_full FDRE)"
q4_area="$(extract_area q4_full)"
baseline_lcs="$(extract_fpga q4_baseline LC)"
baseline_fdre="$(extract_fpga q4_baseline FDRE)"
baseline_area="$(extract_area q4_baseline)"
all_lcs="$(extract_fpga q4_all_enabled LC)"
all_fdre="$(extract_fpga q4_all_enabled FDRE)"
all_area="$(extract_area q4_all_enabled)"

{
    echo "metric,baseline,fairness,change_percent,yosys_version,abc_version"
    echo "fpga_estimated_lcs,${q4_off_lcs},${q4_lcs},$(percent "${q4_off_lcs}" "${q4_lcs}"),${yosys_version},${abc_version}"
    echo "fpga_fdre,${q4_off_fdre},${q4_fdre},$(percent "${q4_off_fdre}" "${q4_fdre}"),${yosys_version},${abc_version}"
    echo "asic_cell_area_um2,${q4_off_area},${q4_area},$(percent "${q4_off_area}" "${q4_area}"),${yosys_version},${abc_version}"
} >"${exp09_metrics}"

{
    echo "metric,one_queue,four_queues,change_percent,per_added_queue,yosys_version,abc_version"
    echo "fpga_estimated_lcs,${q1_lcs},${q4_lcs},$(percent "${q1_lcs}" "${q4_lcs}"),$(awk -v one="${q1_lcs}" -v four="${q4_lcs}" 'BEGIN {printf "%.3f", (four-one)/3}'),${yosys_version},${abc_version}"
    echo "fpga_fdre,${q1_fdre},${q4_fdre},$(percent "${q1_fdre}" "${q4_fdre}"),$(( (q4_fdre-q1_fdre)/3 )),${yosys_version},${abc_version}"
    echo "asic_cell_area_um2,${q1_area},${q4_area},$(percent "${q1_area}" "${q4_area}"),$(awk -v one="${q1_area}" -v four="${q4_area}" 'BEGIN {printf "%.3f", (four-one)/3}'),${yosys_version},${abc_version}"
} >"${exp11_metrics}"

{
    echo "metric,baseline,all_enabled,change_percent,yosys_version,abc_version"
    echo "fpga_estimated_lcs,${baseline_lcs},${all_lcs},$(percent "${baseline_lcs}" "${all_lcs}"),${yosys_version},${abc_version}"
    echo "fpga_fdre,${baseline_fdre},${all_fdre},$(percent "${baseline_fdre}" "${all_fdre}"),${yosys_version},${abc_version}"
    echo "asic_cell_area_um2,${baseline_area},${all_area},$(percent "${baseline_area}" "${all_area}"),${yosys_version},${abc_version}"
} >"${combined_metrics}"

echo "实验9、11和组合PPA完成：${exp09_metrics}，${exp11_metrics}，${combined_metrics}"
