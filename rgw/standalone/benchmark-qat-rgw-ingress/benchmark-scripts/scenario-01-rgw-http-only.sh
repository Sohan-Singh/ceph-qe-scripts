#!/bin/bash
# Scenario 1: RGW HTTP Only
# Traffic Flow: Client --HTTP--> RGW (port 80)
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="01"
SCENARIO_NAME="RGW HTTP Only"
RGW_PORT=80
BUCKET="bench-s01-http"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

# Write RGW spec
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: simple.http
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  rgw_frontend_port: 80
  ssl: false
EOF

# Deploy
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.simple.http"
wait_for_service "rgw.simple.http"

# Build endpoint (HTTP, no SSL)
ENDPOINT=$(build_rgw_endpoints "http" "$RGW_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

# Cleanup service
remove_service "rgw.simple.http"

log "Scenario ${SCENARIO_NUM} complete."
