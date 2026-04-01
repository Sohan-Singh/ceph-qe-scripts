#!/bin/bash
# Scenario 14: Ingress Re-encrypt + QAT at RGW + QAT at Ingress (NOT SUPPORTED)
# Traffic Flow: Client --HTTPS--> Ingress (decrypt/re-encrypt + QAT) --HTTPS--> RGW (SSL + QAT)
#
# *** NOT SUPPORTED NOW - Due to HAProxy Image Build Issue ***
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="14"
SCENARIO_NAME="Ingress Re-encrypt + QAT at Both (NOT SUPPORTED)"
INGRESS_PORT=452
BUCKET="bench-s14-reencrypt-qat-both"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

log "WARNING: This scenario is NOT SUPPORTED due to HAProxy Image Build Issue."
log "WARNING: Deploying specs for validation only. Benchmark may fail."

# Find available VIPs (this scenario needs 2)
INGRESS_VIP_1=$(find_available_vip)
INGRESS_VIP_2=$(find_available_vip)
log "Allocated VIPs: ${INGRESS_VIP_1}, ${INGRESS_VIP_2}"

# Write RGW spec
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: ssl_rgw_reencrypt_three
service_name: rgw.ssl_rgw_reencrypt_three
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  qat:
    compression: hw
  certificate_source: cephadm-signed
  generate_cert: true
  rgw_exit_timeout_secs: 120
  rgw_frontend_port: 8036
  ssl: true
EOF

# Write Ingress spec
cat > "${SPEC_DIR}/ingress.yaml" <<EOF
service_type: ingress
service_id: rgw.ssl_rgw_reencrypt_three
service_name: ingress.qat_dim_auto_vip_three
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  backend_service: rgw.ssl_rgw_reencrypt_three
  first_virtual_router_id: 53
  frontend_port: ${INGRESS_PORT}
  ssl: true
  verify_backend_ssl_cert: true
  generate_cert: true
  haproxy_qat_support: true
  monitor_port: 1974
  virtual_ips_list:
    - ${INGRESS_VIP_1}${VIP_CIDR}
    - ${INGRESS_VIP_2}${VIP_CIDR}
EOF

# Deploy RGW first, then Ingress
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.ssl_rgw_reencrypt_three"
wait_for_service "rgw.ssl_rgw_reencrypt_three"

deploy_service "${SPEC_DIR}/ingress.yaml" "ingress.rgw.ssl_rgw_reencrypt_three"
if ! wait_for_service "ingress.rgw.ssl_rgw_reencrypt_three" 6; then
    log "ERROR: Ingress with QAT failed to deploy (expected - NOT SUPPORTED)."
    remove_service "ingress.rgw.ssl_rgw_reencrypt_three"
    release_vip "$INGRESS_VIP_1"
    release_vip "$INGRESS_VIP_2"
    remove_service "rgw.ssl_rgw_reencrypt_three"
    log "Scenario ${SCENARIO_NUM} skipped (NOT SUPPORTED)."
    exit 0
fi

# Build endpoint (HTTPS via first ingress VIP)
ENDPOINT=$(build_vip_endpoint "https" "$INGRESS_VIP_1" "$INGRESS_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

# Cleanup
remove_service "ingress.rgw.ssl_rgw_reencrypt_three"
release_vip "$INGRESS_VIP_1"
release_vip "$INGRESS_VIP_2"
remove_service "rgw.ssl_rgw_reencrypt_three"

log "Scenario ${SCENARIO_NUM} complete."
