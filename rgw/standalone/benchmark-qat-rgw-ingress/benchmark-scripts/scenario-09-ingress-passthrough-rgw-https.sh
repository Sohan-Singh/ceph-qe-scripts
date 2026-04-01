#!/bin/bash
# Scenario 9: Ingress Passthrough + RGW HTTPS
# Traffic Flow: Client --HTTPS--> Ingress (passthrough) --HTTPS--> RGW (HTTPS)
# End-to-End Encryption - HAProxy in TCP mode
source "$(dirname "$0")/common.sh"

SCENARIO_NUM="09"
SCENARIO_NAME="Ingress Passthrough + RGW HTTPS"
INGRESS_PORT=448
BUCKET="bench-s09-passthrough-https"

init_scenario "$SCENARIO_NUM" "$SCENARIO_NAME"

# Find available VIP
INGRESS_VIP=$(find_available_vip)
log "Allocated VIP: ${INGRESS_VIP}"

# Write RGW spec
cat > "${SPEC_DIR}/rgw.yaml" <<'EOF'
service_type: rgw
service_id: rgw_only_pt
service_name: rgw.rgw_only_pt
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  certificate_source: cephadm-signed
  generate_cert: true
  rgw_exit_timeout_secs: 120
  rgw_frontend_port: 8043
  ssl: true
EOF

# Write Ingress spec (TCP passthrough mode)
cat > "${SPEC_DIR}/ingress.yaml" <<EOF
service_type: ingress
service_id: ingress.passthrough
placement:
  hosts:
    - ceph14
    - ceph15
    - ceph16
spec:
  backend_service: rgw.rgw_only_pt
  certificate_source: cephadm-signed
  virtual_ip: ${INGRESS_VIP}${VIP_CIDR}
  frontend_port: ${INGRESS_PORT}
  monitor_port: 1976
  use_tcp_mode_over_rgw: true
  ssl: false
EOF

# Deploy RGW first, then Ingress
deploy_service "${SPEC_DIR}/rgw.yaml" "rgw.rgw_only_pt"
wait_for_service "rgw.rgw_only_pt"

deploy_service "${SPEC_DIR}/ingress.yaml" "ingress.ingress.passthrough"
wait_for_service "ingress.ingress.passthrough" 6

# Build endpoint (HTTPS via ingress VIP - passthrough to RGW SSL)
ENDPOINT=$(build_vip_endpoint "https" "$INGRESS_VIP" "$INGRESS_PORT")

# Run benchmarks
run_benchmark_suite "$ENDPOINT" "$BUCKET" "$SCENARIO_NAME"

# Cleanup
remove_service "ingress.ingress.passthrough"
release_vip "$INGRESS_VIP"
remove_service "rgw.rgw_only_pt"

log "Scenario ${SCENARIO_NUM} complete."
