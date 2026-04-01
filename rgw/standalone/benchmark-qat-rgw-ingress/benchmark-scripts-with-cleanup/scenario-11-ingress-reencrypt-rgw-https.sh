#!/bin/bash
# Scenario 11: Ingress Re-encrypt + RGW HTTPS
# Traffic Flow: Client --HTTPS--> Ingress (decrypt + re-encrypt) --HTTPS--> RGW (port 8033)
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="11"
SCENARIO_NAME="Ingress Re-encrypt + RGW HTTPS"
INGRESS_PORT=450
BUCKET="bench-s11-reencrypt-https"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

# Find available VIP
INGRESS_VIP=$(find_available_vip)
log "Allocated VIP: ${INGRESS_VIP}"

# Write RGW spec
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: ssl_rgw_reencrypt
service_name: rgw.ssl_rgw_reencrypt
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  certificate_source: cephadm-signed
  generate_cert: true
  rgw_exit_timeout_secs: 120
  rgw_frontend_port: 8033
  ssl: true
EOF

# Write Ingress spec (re-encrypt mode)
cat > "${SPEC_DIR}/ingress.yaml" <<EOF
service_type: ingress
service_id: ssl_ingress_reencrypt
service_name: ingress.ssl_ingress_reencrypt
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  backend_service: rgw.ssl_rgw_reencrypt
  first_virtual_router_id: 56
  frontend_port: ${INGRESS_PORT}
  generate_cert: true
  monitor_port: 1988
  ssl: true
  verify_backend_ssl_cert: true
  virtual_ip: ${INGRESS_VIP}${VIP_CIDR}
EOF

# Deploy RGW first, then Ingress
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.ssl_rgw_reencrypt"
register_cleanup service "rgw.ssl_rgw_reencrypt"
wait_for_service "rgw.ssl_rgw_reencrypt"

deploy_service "${SPEC_DIR}/ingress.yaml" "ingress.ssl_ingress_reencrypt"
register_cleanup service "ingress.ssl_ingress_reencrypt"
register_cleanup vip "$INGRESS_VIP"
wait_for_service "ingress.ssl_ingress_reencrypt" 6

# Build endpoint (HTTPS via ingress VIP)
ENDPOINT=$(build_vip_endpoint "https" "$INGRESS_VIP" "$INGRESS_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

log "Scenario ${SCENARIO_NUM} complete."
