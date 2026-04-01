#!/bin/bash
# Scenario 4: RGW HTTPS + QAT
# Traffic Flow: Client --HTTPS--> RGW (port 8023) with QAT
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="04"
SCENARIO_NAME="RGW HTTPS + QAT"
RGW_PORT=8023
BUCKET="bench-s04-https-qat"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

# Write RGW spec (Hardware QAT)
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: ssl_rgw_qat_hw
service_name: rgw.ssl_rgw_qat_hw
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  certificate_source: cephadm-signed
  generate_cert: true
  qat:
    compression: hw
  rgw_exit_timeout_secs: 120
  rgw_frontend_port: 8023
  ssl: true
EOF

# Deploy
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.ssl_rgw_qat_hw"
wait_for_service "rgw.ssl_rgw_qat_hw"

# Build endpoint (HTTPS)
ENDPOINT=$(build_rgw_endpoints "https" "$RGW_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

# Cleanup service
remove_service "rgw.ssl_rgw_qat_hw"

log "Scenario ${SCENARIO_NUM} complete."
