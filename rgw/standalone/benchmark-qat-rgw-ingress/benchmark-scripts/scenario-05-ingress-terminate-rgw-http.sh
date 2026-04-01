#!/bin/bash
# Scenario 5: Ingress Terminate + RGW HTTP (No QAT)
# Traffic Flow: Client --HTTPS--> Ingress (SSL terminate) --HTTP--> RGW (port 8070)
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="05"
SCENARIO_NAME="Ingress Terminate + RGW HTTP"
INGRESS_PORT=443
BUCKET="bench-s05-terminate-http"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

# Find available VIP
INGRESS_VIP=$(find_available_vip)
log "Allocated VIP: ${INGRESS_VIP}"

# Write RGW spec
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: rgw.nossl.one
service_name: rgw.rgw.nossl.one
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  rgw_frontend_port: 8070
  ssl: false
EOF

# Write Ingress spec (variable expansion for VIP)
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
  backend_service: rgw.rgw.nossl.one
  first_virtual_router_id: 51
  frontend_port: ${INGRESS_PORT}
  ssl: true
  monitor_port: 1983
  virtual_ip: ${INGRESS_VIP}${VIP_CIDR}
EOF

# Deploy RGW first, then Ingress
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.rgw.nossl.one"
wait_for_service "rgw.rgw.nossl.one"

deploy_service "${SPEC_DIR}/ingress.yaml" "ingress.rgw.ssl_qat_ingress_rgw_nossl"
wait_for_service "ingress.rgw.ssl_qat_ingress_rgw_nossl" 6

# Build endpoint (HTTPS via ingress VIP)
ENDPOINT=$(build_vip_endpoint "https" "$INGRESS_VIP" "$INGRESS_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

# Cleanup services (ingress first, then RGW)
remove_service "ingress.rgw.ssl_qat_ingress_rgw_nossl"
release_vip "$INGRESS_VIP"
remove_service "rgw.rgw.nossl.one"

log "Scenario ${SCENARIO_NUM} complete."
