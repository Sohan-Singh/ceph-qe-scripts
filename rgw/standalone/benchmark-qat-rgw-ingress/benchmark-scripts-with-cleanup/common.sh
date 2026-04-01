#!/bin/bash
# common.sh - Shared configuration and functions for all benchmark scenarios
# Source this file from each scenario script: source "$(dirname "$0")/common.sh"

set -eo pipefail

# ============================================================
# CONFIGURATION - Update these before running
# ============================================================
S3_KEY="${S3_KEY:-}"
S3_SECRET="${S3_SECRET:-}"
HOSTS=("ceph14" "ceph15" "ceph16")
HOST_IPS=("10.64.1.14" "10.64.1.15" "10.64.1.16")
RUN_TIMESTAMP="${RUN_TIMESTAMP:-$(date '+%Y%m%d_%H%M%S')}"
RESULTS_BASE="/root/benchmark/results/run_${RUN_TIMESTAMP}"
DEPLOY_WAIT_TIMEOUT=300  # seconds to wait for services to deploy
DEPLOY_POLL_INTERVAL=10  # seconds between status checks

# Validate required variables
if [ -z "$S3_KEY" ] || [ -z "$S3_SECRET" ]; then
    echo "ERROR: S3_KEY and S3_SECRET must be set."
    echo "  export S3_KEY='your-access-key'"
    echo "  export S3_SECRET='your-secret-key'"
    exit 1
fi

# ============================================================
# LOGGING
# ============================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${RESULTS_DIR}/benchmark.log"
}

log_separator() {
    log "================================================================"
}

# ============================================================
# SERVICE DEPLOYMENT
# ============================================================
deploy_service() {
    local spec_file="$1"
    local service_name="$2"
    log "Deploying service: ${service_name}"
    ceph orch apply -i "${spec_file}" 2>&1 | tee -a "${RESULTS_DIR}/deploy.log"
}

wait_for_service() {
    local service_name="$1"
    local expected_count="${2:-3}"
    local elapsed=0

    log "Waiting for service '${service_name}' to have ${expected_count} running daemon(s)..."
    while [ $elapsed -lt $DEPLOY_WAIT_TIMEOUT ]; do
        local running
        running=$(ceph orch ps --service-name "${service_name}" --format json 2>/dev/null \
            | python3 -c "import sys,json; print(sum(1 for d in json.load(sys.stdin) if d.get('status_desc','') == 'running'))" 2>/dev/null || echo 0)

        if [ "$running" -ge "$expected_count" ]; then
            log "Service '${service_name}' is ready (${running}/${expected_count} daemons running)"
            return 0
        fi
        log "  ... ${running}/${expected_count} daemons running, waiting ${DEPLOY_POLL_INTERVAL}s (${elapsed}/${DEPLOY_WAIT_TIMEOUT}s)"
        sleep $DEPLOY_POLL_INTERVAL
        elapsed=$((elapsed + DEPLOY_POLL_INTERVAL))
    done

    log "WARNING: Timed out waiting for service '${service_name}'"
    ceph orch ps --service-name "${service_name}" 2>&1 | tee -a "${RESULTS_DIR}/deploy.log"
    return 1
}

remove_service() {
    local service_name="$1"
    log "Removing service: ${service_name}"
    ceph orch rm "${service_name}" --force 2>&1 | tee -a "${RESULTS_DIR}/deploy.log" || true
    sleep 5
}

# ============================================================
# ENDPOINT HELPERS
# ============================================================
VIP_INTERFACE="${VIP_INTERFACE:-ens3}"
VIP_SUBNET_PREFIX="${VIP_SUBNET_PREFIX:-9.11.120}"
VIP_RANGE_START="${VIP_RANGE_START:-200}"
VIP_RANGE_END="${VIP_RANGE_END:-254}"
VIP_CIDR="${VIP_CIDR:-/23}"
# Track allocated VIPs within this session to avoid reuse
_VIP_ALLOCATED_FILE="/tmp/benchmark_vips_allocated.$$"

find_available_vip() {
    local prefix="${1:-$VIP_SUBNET_PREFIX}"
    local start="${2:-$VIP_RANGE_START}"
    local end="${3:-$VIP_RANGE_END}"

    for i in $(seq "$start" "$end"); do
        local candidate="${prefix}.${i}"
        # Skip if already allocated in this session
        if [ -f "$_VIP_ALLOCATED_FILE" ] && grep -q "^${candidate}$" "$_VIP_ALLOCATED_FILE" 2>/dev/null; then
            continue
        fi
        # Check if IP is unused via arping
        if ! arping -c1 -W1 -I "$VIP_INTERFACE" "$candidate" &>/dev/null; then
            echo "$candidate"
            echo "$candidate" >> "$_VIP_ALLOCATED_FILE"
            return 0
        fi
    done

    log "ERROR: No available VIP found in ${prefix}.${start}-${end}"
    return 1
}

release_vip() {
    local vip="$1"
    if [ -f "$_VIP_ALLOCATED_FILE" ]; then
        grep -v "^${vip}$" "$_VIP_ALLOCATED_FILE" > "${_VIP_ALLOCATED_FILE}.tmp" 2>/dev/null || true
        mv "${_VIP_ALLOCATED_FILE}.tmp" "$_VIP_ALLOCATED_FILE"
    fi
}

build_rgw_endpoints() {
    local protocol="$1"
    local port="$2"
    local endpoints=""
    for ip in "${HOST_IPS[@]}"; do
        [ -n "$endpoints" ] && endpoints="${endpoints},"
        endpoints="${endpoints}${protocol}://${ip}:${port}"
    done
    echo "$endpoints"
}

build_vip_endpoint() {
    local protocol="$1"
    local vip="$2"
    local port="$3"
    # Strip CIDR notation from VIP
    local ip="${vip%%/*}"
    echo "${protocol}://${ip}:${port}"
}

# ============================================================
# BENCHMARK FUNCTIONS
# ============================================================
run_benchmark_suite() {
    local endpoint="$1"
    local bucket="$2"
    local scenario_name="$3"

    log_separator
    log "BENCHMARK SUITE: ${scenario_name}"
    log "Endpoint: ${endpoint}"
    log "Bucket: ${bucket}"
    log_separator

    # Record cluster state before benchmark
    log "--- Cluster Status (Before) ---"
    ceph -s 2>&1 | tee -a "${RESULTS_DIR}/cluster_status.log"

    # Step 1: Create bucket
    log "--- Step 1: Create Bucket ---"
    elbencho --s3endpoints "${endpoint}" --s3key "${S3_KEY}" --s3secret "${S3_SECRET}" \
        -d "${bucket}" 2>&1 | tee -a "${RESULTS_DIR}/01_create_bucket.log"

    # Step 2: Small objects (4KB) - IOPS test
    log "--- Step 2: Write Small Objects (4KB x 160,000) ---"
    elbencho --s3endpoints "${endpoint}" --s3key "${S3_KEY}" --s3secret "${S3_SECRET}" \
        -w -t 16 -n 100 -N 100 -s 4k -b 4k --lat \
        "${bucket}" 2>&1 | tee -a "${RESULTS_DIR}/02_write_4k.log"

    # Step 3: Read small objects
    log "--- Step 3: Read Small Objects (4KB x 160,000) ---"
    elbencho --s3endpoints "${endpoint}" --s3key "${S3_KEY}" --s3secret "${S3_SECRET}" \
        -r -t 16 -n 100 -N 100 -s 4k -b 4k --lat --s3fastget \
        "${bucket}" 2>&1 | tee -a "${RESULTS_DIR}/03_read_4k.log"

    # Step 4: Delete small objects
    log "--- Step 4: Cleanup Small Objects ---"
    elbencho --s3endpoints "${endpoint}" --s3key "${S3_KEY}" --s3secret "${S3_SECRET}" \
        -F -t 16 -n 100 -N 100 \
        "${bucket}" 2>&1 | tee -a "${RESULTS_DIR}/04_delete_4k.log"

    # Step 5: Medium objects (1MB) - balanced test
    log "--- Step 5: Write Medium Objects (1MB x 32,000) ---"
    elbencho --s3endpoints "${endpoint}" --s3key "${S3_KEY}" --s3secret "${S3_SECRET}" \
        -w -t 32 -n 10 -N 100 -s 1m -b 1m --lat \
        "${bucket}" 2>&1 | tee -a "${RESULTS_DIR}/05_write_1m.log"

    # Step 6: Read medium objects
    log "--- Step 6: Read Medium Objects (1MB x 32,000) ---"
    elbencho --s3endpoints "${endpoint}" --s3key "${S3_KEY}" --s3secret "${S3_SECRET}" \
        -r -t 32 -n 10 -N 100 -s 1m -b 1m --lat --s3fastget \
        "${bucket}" 2>&1 | tee -a "${RESULTS_DIR}/06_read_1m.log"

    # Step 7: Delete medium objects
    log "--- Step 7: Cleanup Medium Objects ---"
    elbencho --s3endpoints "${endpoint}" --s3key "${S3_KEY}" --s3secret "${S3_SECRET}" \
        -F -t 32 -n 10 -N 100 \
        "${bucket}" 2>&1 | tee -a "${RESULTS_DIR}/07_delete_1m.log"

    # Step 8: Large objects (10MB) - throughput test
    log "--- Step 8: Write Large Objects (10MB x 3,200) ---"
    elbencho --s3endpoints "${endpoint}" --s3key "${S3_KEY}" --s3secret "${S3_SECRET}" \
        -w -t 32 -n 5 -N 20 -s 10m -b 5m --lat \
        "${bucket}" 2>&1 | tee -a "${RESULTS_DIR}/08_write_10m.log"

    # Step 9: Read large objects
    log "--- Step 9: Read Large Objects (10MB x 3,200) ---"
    elbencho --s3endpoints "${endpoint}" --s3key "${S3_KEY}" --s3secret "${S3_SECRET}" \
        -r -t 32 -n 5 -N 20 -s 10m -b 5m --lat --s3fastget \
        "${bucket}" 2>&1 | tee -a "${RESULTS_DIR}/09_read_10m.log"

    # Step 10: Delete large objects
    log "--- Step 10: Cleanup Large Objects ---"
    elbencho --s3endpoints "${endpoint}" --s3key "${S3_KEY}" --s3secret "${S3_SECRET}" \
        -F -t 32 -n 5 -N 20 \
        "${bucket}" 2>&1 | tee -a "${RESULTS_DIR}/10_delete_10m.log"

    # Step 11: Delete bucket
    log "--- Step 11: Delete Bucket ---"
    elbencho --s3endpoints "${endpoint}" --s3key "${S3_KEY}" --s3secret "${S3_SECRET}" \
        -D "${bucket}" 2>&1 | tee -a "${RESULTS_DIR}/11_delete_bucket.log"

    # Record cluster state after benchmark
    log "--- Cluster Status (After) ---"
    ceph -s 2>&1 | tee -a "${RESULTS_DIR}/cluster_status.log"

    log_separator
    log "BENCHMARK SUITE COMPLETE: ${scenario_name}"
    log "Results saved to: ${RESULTS_DIR}"
    log_separator
}

# ============================================================
# CLEANUP TRAP - ensures services are removed even on failure
# ============================================================
_CLEANUP_SERVICES=()
_CLEANUP_VIPS=()

register_cleanup() {
    # Register a service for cleanup on exit
    # Usage: register_cleanup service "service_name"
    #        register_cleanup vip "10.1.2.3"
    local type="$1"
    local name="$2"
    if [ "$type" = "service" ]; then
        _CLEANUP_SERVICES+=("$name")
    elif [ "$type" = "vip" ]; then
        _CLEANUP_VIPS+=("$name")
    fi
}

_run_cleanup() {
    local exit_code=$?
    if [ ${#_CLEANUP_SERVICES[@]} -gt 0 ]; then
        log "--- Running cleanup (exit code: ${exit_code}) ---"
        for svc in "${_CLEANUP_SERVICES[@]}"; do
            remove_service "$svc"
        done
        for vip in "${_CLEANUP_VIPS[@]}"; do
            release_vip "$vip"
        done
    fi
}

trap _run_cleanup EXIT

# ============================================================
# SCENARIO INIT
# ============================================================
init_scenario() {
    local scenario_num="$1"
    local scenario_name="$2"
    RESULTS_DIR="${RESULTS_BASE}/scenario-${scenario_num}-$(echo "${scenario_name}" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')"
    SPEC_DIR="${RESULTS_DIR}/specs"
    mkdir -p "${RESULTS_DIR}" "${SPEC_DIR}"
    # Reset cleanup lists for this scenario
    _CLEANUP_SERVICES=()
    _CLEANUP_VIPS=()
    log_separator
    log "SCENARIO ${scenario_num}: ${scenario_name}"
    log_separator
}
