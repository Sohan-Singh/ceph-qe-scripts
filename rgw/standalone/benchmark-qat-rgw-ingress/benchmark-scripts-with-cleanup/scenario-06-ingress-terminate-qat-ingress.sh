#!/bin/bash
# Scenario 6: Ingress Terminate + QAT at Ingress (NOT SUPPORTED)
# Traffic Flow: Client --HTTPS--> Ingress (SSL terminate + QAT) --HTTP--> RGW
#
# *** NOT SUPPORTED NOW - Due to HAProxy Image Build Issue ***
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="06"
SCENARIO_NAME="Ingress Terminate + QAT at Ingress (NOT SUPPORTED)"
INGRESS_PORT=444
BUCKET="bench-s06-terminate-qat-ingress"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

log "WARNING: This scenario is NOT SUPPORTED due to HAProxy Image Build Issue."
log "WARNING: Deploying specs for validation only. Benchmark may fail."

# Find available VIP
INGRESS_VIP=$(find_available_vip)
log "Allocated VIP: ${INGRESS_VIP}"

# Write RGW spec
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: rgw.nossl.one
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  rgw_frontend_port: 8071
  ssl: false
EOF

# Write Ingress spec
cat > "${SPEC_DIR}/ingress.yaml" <<EOF
service_type: ingress
service_id: rgw.ssl_qat_ingress_rgw_nossl
service_name: ingress.qat_ingress_rgw_nossl
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  backend_service: rgw.nossl.one
  first_virtual_router_id: 54
  frontend_port: ${INGRESS_PORT}
  ssl: true
  monitor_port: 1984
  virtual_ip: ${INGRESS_VIP}${VIP_CIDR}
EOF

# Deploy RGW first, then Ingress
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.nossl.one"
register_cleanup service "rgw.nossl.one"
wait_for_service "rgw.nossl.one"

deploy_service "${SPEC_DIR}/ingress.yaml" "ingress.rgw.ssl_qat_ingress_rgw_nossl"
register_cleanup service "ingress.rgw.ssl_qat_ingress_rgw_nossl"
register_cleanup vip "$INGRESS_VIP"
if ! wait_for_service "ingress.rgw.ssl_qat_ingress_rgw_nossl" 6; then
    log "ERROR: Ingress with QAT failed to deploy (expected - NOT SUPPORTED)."
    log "Scenario ${SCENARIO_NUM} skipped (NOT SUPPORTED)."
    exit 0
fi

# Build endpoint (HTTPS via ingress VIP)
ENDPOINT=$(build_vip_endpoint "https" "$INGRESS_VIP" "$INGRESS_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

log "Scenario ${SCENARIO_NUM} complete."
