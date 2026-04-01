#!/bin/bash
# Scenario 13: Ingress Re-encrypt + QAT at RGW
# Traffic Flow: Client --HTTPS--> Ingress (decrypt/re-encrypt) --HTTPS--> RGW (SSL + QAT)
# Only valid QAT re-encrypt case (QAT at RGW only)
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="13"
SCENARIO_NAME="Ingress Re-encrypt + QAT at RGW"
INGRESS_PORT=451
BUCKET="bench-s13-reencrypt-qat-rgw"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

# Find available VIPs (this scenario needs 2)
INGRESS_VIP_1=$(find_available_vip)
INGRESS_VIP_2=$(find_available_vip)
log "Allocated VIPs: ${INGRESS_VIP_1}, ${INGRESS_VIP_2}"

# Write RGW spec
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: ssl_rgw_reencrypt_two
service_name: rgw.ssl_rgw_reencrypt_two
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
  rgw_frontend_port: 8035
  ssl: true
EOF

# Write Ingress spec (re-encrypt mode, no QAT at ingress)
cat > "${SPEC_DIR}/ingress.yaml" <<EOF
service_type: ingress
service_id: rgw.ssl_rgw_reencrypt_two
service_name: ingress.qat_dim_auto_vip_two
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  backend_service: rgw.ssl_rgw_reencrypt_two
  first_virtual_router_id: 58
  frontend_port: ${INGRESS_PORT}
  ssl: true
  generate_cert: true
  verify_backend_ssl_cert: true
  monitor_port: 1975
  virtual_ips_list:
    - ${INGRESS_VIP_1}${VIP_CIDR}
    - ${INGRESS_VIP_2}${VIP_CIDR}
EOF

# Deploy RGW first, then Ingress
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.ssl_rgw_reencrypt_two"
register_cleanup service "rgw.ssl_rgw_reencrypt_two"
wait_for_service "rgw.ssl_rgw_reencrypt_two"

deploy_service "${SPEC_DIR}/ingress.yaml" "ingress.rgw.ssl_rgw_reencrypt_two"
register_cleanup service "ingress.rgw.ssl_rgw_reencrypt_two"
register_cleanup vip "$INGRESS_VIP_1"
register_cleanup vip "$INGRESS_VIP_2"
wait_for_service "ingress.rgw.ssl_rgw_reencrypt_two" 6

# Build endpoint (HTTPS via first ingress VIP)
ENDPOINT=$(build_vip_endpoint "https" "$INGRESS_VIP_1" "$INGRESS_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

log "Scenario ${SCENARIO_NUM} complete."
