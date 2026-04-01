#!/bin/bash
# Scenario 3: RGW HTTPS Only (No Ingress, No QAT)
# Traffic Flow: Client --HTTPS--> RGW (port 8022)
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="03"
SCENARIO_NAME="RGW HTTPS Only"
RGW_PORT=8022
BUCKET="bench-s03-https"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

# Write RGW spec
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: ssl_rgw_only
service_name: rgw.ssl_rgw_only
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  certificate_source: cephadm-signed
  generate_cert: true
  rgw_exit_timeout_secs: 120
  rgw_frontend_port: 8022
  ssl: true
EOF

# Deploy
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.ssl_rgw_only"
register_cleanup service "rgw.ssl_rgw_only"
wait_for_service "rgw.ssl_rgw_only"

# Build endpoint (HTTPS)
ENDPOINT=$(build_rgw_endpoints "https" "$RGW_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

log "Scenario ${SCENARIO_NUM} complete."
