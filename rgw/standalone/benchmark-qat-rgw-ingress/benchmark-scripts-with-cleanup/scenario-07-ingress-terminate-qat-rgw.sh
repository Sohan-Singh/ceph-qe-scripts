#!/bin/bash
# Scenario 7: Ingress Terminate + QAT at RGW
# Traffic Flow: Client --HTTPS--> Ingress (SSL terminate) --HTTP--> RGW (QAT compression)
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="07"
SCENARIO_NAME="Ingress Terminate + QAT at RGW"
INGRESS_PORT=445
BUCKET="bench-s07-terminate-qat-rgw"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

# Find available VIP
INGRESS_VIP=$(find_available_vip)
log "Allocated VIP: ${INGRESS_VIP}"

# Write RGW spec
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: rgw.nossl.two
service_name: rgw.rgw.nossl.two
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  qat:
    compression: hw
  rgw_frontend_port: 8095
  ssl: false
EOF

# Write Ingress spec
cat > "${SPEC_DIR}/ingress.yaml" <<EOF
service_type: ingress
service_id: ingress.qat_ingress_rgw_nossl_two
service_name: ingress.qat_ingress_rgw_nossl_two
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  backend_service: rgw.rgw.nossl.two
  first_virtual_router_id: 52
  frontend_port: ${INGRESS_PORT}
  ssl: true
  monitor_port: 1986
  virtual_ip: ${INGRESS_VIP}${VIP_CIDR}
EOF

# Deploy RGW first, then Ingress
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.rgw.nossl.two"
register_cleanup service "rgw.rgw.nossl.two"
wait_for_service "rgw.rgw.nossl.two"

deploy_service "${SPEC_DIR}/ingress.yaml" "ingress.ingress.qat_ingress_rgw_nossl_two"
register_cleanup service "ingress.ingress.qat_ingress_rgw_nossl_two"
register_cleanup vip "$INGRESS_VIP"
wait_for_service "ingress.ingress.qat_ingress_rgw_nossl_two" 6

# Build endpoint (HTTPS via ingress VIP)
ENDPOINT=$(build_vip_endpoint "https" "$INGRESS_VIP" "$INGRESS_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

log "Scenario ${SCENARIO_NUM} complete."
