#!/bin/bash
# Scenario 8: Ingress Terminate + QAT at RGW + QAT at Backend (NOT SUPPORTED)
# Traffic Flow: Client --HTTPS--> Ingress (SSL terminate + QAT) --HTTP--> RGW (QAT)
#
# *** NOT SUPPORTED NOW - Due to HAProxy Image Build Issue ***
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="08"
SCENARIO_NAME="Ingress Terminate + QAT at Both (NOT SUPPORTED)"
INGRESS_PORT=446
BUCKET="bench-s08-terminate-qat-both"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

log "WARNING: This scenario is NOT SUPPORTED due to HAProxy Image Build Issue."
log "WARNING: Deploying specs for validation only. Benchmark may fail."

# Find available VIP
INGRESS_VIP=$(find_available_vip)
log "Allocated VIP: ${INGRESS_VIP}"

# Write RGW spec
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: rgw.nossl.three
service_name: rgw.rgw.nossl.three
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  qat:
    compression: hw
  rgw_frontend_port: 8081
  ssl: false
EOF

# Write Ingress spec
cat > "${SPEC_DIR}/ingress.yaml" <<EOF
service_type: ingress
service_id: ingress.qat_ingress_rgw_nossl_three
service_name: ingress.qat_ingress_rgw_nossl_three
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  backend_service: rgw.rgw.nossl.three
  first_virtual_router_id: 55
  frontend_port: ${INGRESS_PORT}
  haproxy_qat_support: true
  ssl: true
  monitor_port: 1993
  virtual_ip: ${INGRESS_VIP}${VIP_CIDR}
EOF

# Deploy RGW first, then Ingress
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.rgw.nossl.three"
register_cleanup service "rgw.rgw.nossl.three"
wait_for_service "rgw.rgw.nossl.three"

deploy_service "${SPEC_DIR}/ingress.yaml" "ingress.ingress.qat_ingress_rgw_nossl_three"
register_cleanup service "ingress.ingress.qat_ingress_rgw_nossl_three"
register_cleanup vip "$INGRESS_VIP"
if ! wait_for_service "ingress.ingress.qat_ingress_rgw_nossl_three" 6; then
    log "ERROR: Ingress with QAT failed to deploy (expected - NOT SUPPORTED)."
    log "Scenario ${SCENARIO_NUM} skipped (NOT SUPPORTED)."
    exit 0
fi

# Build endpoint (HTTPS via ingress VIP)
ENDPOINT=$(build_vip_endpoint "https" "$INGRESS_VIP" "$INGRESS_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

log "Scenario ${SCENARIO_NUM} complete."
