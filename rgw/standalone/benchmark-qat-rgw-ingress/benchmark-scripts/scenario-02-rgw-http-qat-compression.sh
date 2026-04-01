#!/bin/bash
# Scenario 2: RGW HTTP + QAT Compression
# Traffic Flow: Client --HTTP--> RGW (port 8001) with QAT compression
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="02"
SCENARIO_NAME="RGW HTTP + QAT Compression"
RGW_PORT=8001
BUCKET="bench-s02-http-qat"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

# Write RGW spec (Hardware QAT)
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: nossl_rgw_qat_hw
service_name: rgw.nossl_rgw_qat_hw
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  qat:
    compression: hw
  rgw_exit_timeout_secs: 120
  rgw_frontend_port: 8001
EOF

# Deploy
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.nossl_rgw_qat_hw"
wait_for_service "rgw.nossl_rgw_qat_hw"

# Build endpoint (HTTP, no SSL)
ENDPOINT=$(build_rgw_endpoints "http" "$RGW_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

# Cleanup service
remove_service "rgw.nossl_rgw_qat_hw"

log "Scenario ${SCENARIO_NUM} complete."
