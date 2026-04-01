#!/bin/bash
# Scenario 10: Ingress Passthrough + RGW HTTPS + QAT at RGW
# Traffic Flow: Client --HTTPS--> Ingress (passthrough) --HTTPS--> RGW (SSL + QAT)
# End-to-End Encryption with QAT compression at backend
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="10"
SCENARIO_NAME="Ingress Passthrough + RGW HTTPS + QAT"
INGRESS_PORT=449
BUCKET="bench-s10-passthrough-qat"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

# Find available VIP
INGRESS_VIP=$(find_available_vip)
log "Allocated VIP: ${INGRESS_VIP}"

# Write RGW spec
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: rgw_only_pt_qat
service_name: rgw.rgw_only_pt_qat
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
  rgw_frontend_port: 8044
  ssl: true
EOF

# Write Ingress spec (TCP passthrough mode)
cat > "${SPEC_DIR}/ingress.yaml" <<EOF
service_type: ingress
service_id: ingress.passthrough.two
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  backend_service: rgw.rgw_only_pt_qat
  frontend_port: ${INGRESS_PORT}
  virtual_ip: ${INGRESS_VIP}${VIP_CIDR}
  monitor_port: 1977
  use_tcp_mode_over_rgw: true
  ssl: false
EOF

# Deploy RGW first, then Ingress
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.rgw_only_pt_qat"
wait_for_service "rgw.rgw_only_pt_qat"

deploy_service "${SPEC_DIR}/ingress.yaml" "ingress.ingress.passthrough.two"
wait_for_service "ingress.ingress.passthrough.two" 6

# Build endpoint (HTTPS via ingress VIP - passthrough to RGW SSL)
ENDPOINT=$(build_vip_endpoint "https" "$INGRESS_VIP" "$INGRESS_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

# Cleanup
remove_service "ingress.ingress.passthrough.two"
release_vip "$INGRESS_VIP"
remove_service "rgw.rgw_only_pt_qat"

log "Scenario ${SCENARIO_NUM} complete."
