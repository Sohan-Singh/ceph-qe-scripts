#!/bin/bash
# run-all.sh - Run all 14 RGW/Ingress/QAT benchmark scenarios sequentially
#
# Usage:
#   ./run-all.sh                  # Run all scenarios
#   ./run-all.sh --supported      # Run only supported scenarios (skip 6, 8, 12, 14)
#   ./run-all.sh --scenario 5     # Run a single scenario
#   ./run-all.sh --range 5 10     # Run scenarios 5 through 10

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-all}"

# Validate S3 credentials before launching any scenarios
if [ -z "${S3_KEY:-}" ] || [ -z "${S3_SECRET:-}" ]; then
    echo "ERROR: S3_KEY and S3_SECRET must be exported before running."
    echo "  export S3_KEY='your-access-key'"
    echo "  export S3_SECRET='your-secret-key'"
    exit 1
fi
export S3_KEY S3_SECRET

# Set timestamp FIRST, then derive RESULTS_BASE from it
export RUN_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
RESULTS_BASE="/root/benchmark/results/run_${RUN_TIMESTAMP}"

SUPPORTED_SCENARIOS=(1 2 3 4 5 7 9 10 11 13)
ALL_SCENARIOS=(1 2 3 4 5 6 7 8 9 10 11 12 13 14)

select_scenarios() {
    case "$MODE" in
        --supported)
            SCENARIOS=("${SUPPORTED_SCENARIOS[@]}")
            echo "Running SUPPORTED scenarios only: ${SCENARIOS[*]}"
            ;;
        --scenario)
            SCENARIOS=("$2")
            echo "Running single scenario: ${SCENARIOS[*]}"
            ;;
        --range)
            SCENARIOS=()
            for ((i=$2; i<=$3; i++)); do
                SCENARIOS+=("$i")
            done
            echo "Running scenarios: ${SCENARIOS[*]}"
            ;;
        *)
            SCENARIOS=("${ALL_SCENARIOS[@]}")
            echo "Running ALL scenarios: ${SCENARIOS[*]}"
            ;;
    esac
}

select_scenarios "$@"

mkdir -p "$RESULTS_BASE"
SUMMARY_LOG="${RESULTS_BASE}/run-all-summary.log"

echo "================================================================" | tee -a "$SUMMARY_LOG"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] BENCHMARK RUN STARTED" | tee -a "$SUMMARY_LOG"
echo "Scenarios: ${SCENARIOS[*]}" | tee -a "$SUMMARY_LOG"
echo "================================================================" | tee -a "$SUMMARY_LOG"

PASSED=0
FAILED=0
SKIPPED=0

for scenario_num in "${SCENARIOS[@]}"; do
    padded=$(printf "%02d" "$scenario_num")
    script=$(ls "${SCRIPT_DIR}/scenario-${padded}-"*.sh 2>/dev/null | head -1)

    if [ -z "$script" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SCENARIO ${padded}: Script not found - SKIPPED" | tee -a "$SUMMARY_LOG"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    echo "" | tee -a "$SUMMARY_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SCENARIO ${padded}: Starting - $(basename "$script")" | tee -a "$SUMMARY_LOG"

    if bash "$script" 2>&1 | tee -a "${RESULTS_BASE}/scenario-${padded}.out"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SCENARIO ${padded}: PASSED" | tee -a "$SUMMARY_LOG"
        PASSED=$((PASSED + 1))
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SCENARIO ${padded}: FAILED (exit code: $?)" | tee -a "$SUMMARY_LOG"
        FAILED=$((FAILED + 1))
    fi
done

echo "" | tee -a "$SUMMARY_LOG"
echo "================================================================" | tee -a "$SUMMARY_LOG"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] BENCHMARK RUN COMPLETE" | tee -a "$SUMMARY_LOG"
echo "  Passed:  ${PASSED}" | tee -a "$SUMMARY_LOG"
echo "  Failed:  ${FAILED}" | tee -a "$SUMMARY_LOG"
echo "  Skipped: ${SKIPPED}" | tee -a "$SUMMARY_LOG"
echo "  Total:   ${#SCENARIOS[@]}" | tee -a "$SUMMARY_LOG"
echo "  Results: ${RESULTS_BASE}" | tee -a "$SUMMARY_LOG"
echo "================================================================" | tee -a "$SUMMARY_LOG"
