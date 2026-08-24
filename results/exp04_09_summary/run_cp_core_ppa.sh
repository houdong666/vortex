#!/usr/bin/env bash
set -euo pipefail

# 固定同一综合顶层和工具版本，避免把局部模块数据或旧版 Yosys 崩溃混入对比。
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
build_dir="${VORTEX_BUILD_DIR:-${repo_dir}/build}"
sv2v_bin="${SV2V_BIN:-/home/houdong/tool/sv2v/bin/sv2v}"
yosys_bin="${YOSYS_BIN:-/home/houdong/tool/yosys-0.40/bin/yosys}"
abc_bin="$(dirname "${yosys_bin}")/yosys-abc"
output_dir="${repo_dir}/results/exp04_09_summary/ppa"
metrics_file="${repo_dir}/results/exp04_09_summary/whole_cp_ppa_metrics.csv"
liberty_file="${repo_dir}/hw/syn/libs/NangateOpenCellLibrary_typical.lib"
temp_dir="$(mktemp -d /tmp/vortex-cp-ppa.XXXXXX)"
flat_verilog="${temp_dir}/cp_core_flat.v"

trap 'rm -rf "${temp_dir}"' EXIT

test -x "${sv2v_bin}"
test -x "${yosys_bin}"
test -x "${abc_bin}"
test -f "${build_dir}/hw/VX_config.vh"

yosys_version="$(${yosys_bin} -V | awk '{print $2}')"
abc_version="$(${abc_bin} -c version 2>&1 | awk '/UC Berkeley/ {print $5; exit}')"
oldest_version="$(printf '%s\n' 0.40 "${yosys_version}" | sort -V | head -n 1)"
if [[ "${oldest_version}" != "0.40" ]]; then
    echo "错误：完整 CP 综合要求 Yosys >= 0.40，当前版本为 ${yosys_version}" >&2
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

run_synthesis() {
    local scenario="$1"
    local parameters="$2"
    local log_file="${output_dir}/${scenario}/fpga_yosys040_q4.log"

    mkdir -p "$(dirname "${log_file}")"
    "${yosys_bin}" -Q -p \
        "read_verilog -defer ${flat_verilog}; chparam -set NUM_QUEUES 4 ${parameters} VX_cp_core_top; synth_xilinx -flatten -family xc7 -top VX_cp_core_top; stat" \
        >"${log_file}" 2>&1
}

run_synthesis baseline ""
run_synthesis all_enabled \
    "-set ENABLE_NOP_FAST_PATH 1 -set PREFETCH_DEPTH 2 -set ENABLE_PRIORITY_ARBITRATION 1 -set ENABLE_ARBITRATION_AGING 1 -set ENABLE_EVENT_WAIT_FAIRNESS 1"

run_asic_synthesis() {
    local scenario="$1"
    local parameters="$2"
    local report_dir="${output_dir}/${scenario}/asic400_reports"
    local log_file="${report_dir}/yosys.log"

    mkdir -p "${report_dir}"
    # 未布局标准单元流只用于同口径面积比较，Fmax 必须留给带缓冲和布局布线的流程。
    "${yosys_bin}" -q -p \
        "read_liberty -lib ${liberty_file}; read_verilog -defer ${flat_verilog}; chparam -set NUM_QUEUES 4 ${parameters} VX_cp_core_top; hierarchy -check -top VX_cp_core_top; proc; opt; fsm; opt; memory; opt; memory_map; opt; alumacc; wreduce; share; opt; techmap; opt; dfflibmap -liberty ${liberty_file}; abc -markgroups -D 2.5 -liberty ${liberty_file}; tee -o ${report_dir}/stat_lib.rpt stat -liberty ${liberty_file} -top VX_cp_core_top -width -tech cmos; check" \
        >"${log_file}" 2>&1
}

run_asic_synthesis baseline ""
run_asic_synthesis all_enabled \
    "-set ENABLE_NOP_FAST_PATH 1 -set PREFETCH_DEPTH 2 -set ENABLE_PRIORITY_ARBITRATION 1 -set ENABLE_ARBITRATION_AGING 1 -set ENABLE_EVENT_WAIT_FAIRNESS 1"

extract_last() {
    local pattern="$1"
    local log_file="$2"
    awk -v pattern="${pattern}" '$1 == pattern {value=$NF} END {print value}' "${log_file}"
}

baseline_log="${output_dir}/baseline/fpga_yosys040_q4.log"
optimized_log="${output_dir}/all_enabled/fpga_yosys040_q4.log"
baseline_asic_report="${output_dir}/baseline/asic400_reports/stat_lib.rpt"
optimized_asic_report="${output_dir}/all_enabled/asic400_reports/stat_lib.rpt"
baseline_lcs="$(awk '/Estimated number of LCs:/ {value=$NF} END {print value}' "${baseline_log}")"
optimized_lcs="$(awk '/Estimated number of LCs:/ {value=$NF} END {print value}' "${optimized_log}")"
lcs_delta="$(awk -v base="${baseline_lcs}" -v opt="${optimized_lcs}" 'BEGIN {printf "%.2f", (opt-base)*100/base}')"
baseline_asic_area="$(awk '/Chip area for top module/ {value=$NF} END {print value}' "${baseline_asic_report}")"
optimized_asic_area="$(awk '/Chip area for top module/ {value=$NF} END {print value}' "${optimized_asic_report}")"
asic_area_delta="$(awk -v base="${baseline_asic_area}" -v opt="${optimized_asic_area}" 'BEGIN {printf "%.2f", (opt-base)*100/base}')"

{
    echo "scenario,num_queues,estimated_lcs,fdre,fdse,ram32m,ram64m,asic_area_um2,yosys_version,abc_version,check"
    echo "baseline,4,${baseline_lcs},$(extract_last FDRE "${baseline_log}"),$(extract_last FDSE "${baseline_log}"),$(extract_last RAM32M "${baseline_log}"),$(extract_last RAM64M "${baseline_log}"),${baseline_asic_area},${yosys_version},${abc_version},PASS"
    echo "all_enabled,4,${optimized_lcs},$(extract_last FDRE "${optimized_log}"),$(extract_last FDSE "${optimized_log}"),$(extract_last RAM32M "${optimized_log}"),$(extract_last RAM64M "${optimized_log}"),${optimized_asic_area},${yosys_version},${abc_version},PASS"
    echo "delta_percent,4,${lcs_delta},NA,NA,NA,NA,${asic_area_delta},${yosys_version},${abc_version},PASS"
} >"${metrics_file}"

echo "完整 CP 面积代理完成：FPGA ${baseline_lcs} -> ${optimized_lcs} LCs（${lcs_delta}%），ASIC ${baseline_asic_area} -> ${optimized_asic_area} um^2（${asic_area_delta}%）"
