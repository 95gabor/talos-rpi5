#!/bin/bash
# BSD Zero Clause License — see header in upstream gist.
#
# Fan control for Raspberry Pi 5 + Talos when pwm-rp1 is missing from the kernel.
# https://github.com/siderolabs/sbc-raspberrypi/issues/90
# Adapted from https://gist.github.com/serialx/d3213768026b15222ec8b86d92c06819
#
# Programs RP1 PWM1 channel 3 (GPIO45 / official active cooler) via a privileged
# pod that mmap's the RP1 PCIe BAR — same layout as drivers/pwm/pwm-rp1.c.
#
# Prerequisites: kubectl, a running cluster, RP1 at 0002:01:00.0 (Pi 5 default).
#
# Usage:
#   export FAN_NODE=raspberrypi-7c    # or NODE=... (kubectl node name)
#   export TALOS_ENDPOINTS=192.168.1.24
#   ./scripts/rpi5-fan-control.sh status
#   ./scripts/rpi5-fan-control.sh 75|off|max

set -euo pipefail

NODE="${FAN_NODE:-${NODE:-}}"
NAMESPACE="${FAN_NAMESPACE:-kube-system}"
POD_NAME="${FAN_POD_NAME:-fan-ctl}"
CM_NAME="${FAN_CM_NAME:-fan-ctl-script}"
RP1_PCI="${RP1_PCI_RESOURCE:-/host-sys/bus/pci/devices/0002:01:00.0/resource1}"

resolve_node() {
  if [ -n "$NODE" ]; then
    return
  fi
  NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "$NODE" ]; then
    echo "Set FAN_NODE or NODE (kubectl get nodes)." >&2
    exit 1
  fi
}

cleanup() {
  kubectl delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete configmap "$CM_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
}

usage() {
  echo "Usage: $0 <0-100|status|off|max>"
  echo ""
  echo "  FAN_NODE / NODE   Kubernetes node name (required for status if multiple nodes)"
  echo "  TALOS_ENDPOINTS   Talos API IP (talosctl -e)"
  exit 1
}

if [ $# -lt 1 ]; then
  usage
fi

case "$1" in
  status)
    if [ -z "${TALOS_ENDPOINTS:-}" ]; then
      echo "Set TALOS_ENDPOINTS (Talos API address, e.g. 192.168.1.24)" >&2
      exit 1
    fi
    talosctl_args=(-e "$TALOS_ENDPOINTS")
    if [ -n "$NODE" ]; then
      talosctl_args+=(-n "$NODE")
    fi
    if ! temp="$(talosctl "${talosctl_args[@]}" read /sys/class/thermal/thermal_zone0/temp 2>&1)"; then
      echo "$temp" >&2
      if [ -z "$NODE" ]; then
        echo "Hint: set NODE or FAN_NODE to the Talos node name (kubectl get nodes)." >&2
      fi
      exit 1
    fi
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "${SCRIPT_DIR}/rpi5-fan.py" status "$temp"
    last="$(kubectl logs -n kube-system -l app=rpi5-fan-control --tail=1 2>/dev/null || true)"
    if [[ "$last" == Fan:* ]]; then
      echo "Fan (last applied):    ${last#Fan: }"
    fi
    exit 0
    ;;
  off) SPEED_PERCENT=0 ;;
  max) SPEED_PERCENT=100 ;;
  *)
    SPEED_PERCENT="$1"
    if ! [[ "$SPEED_PERCENT" =~ ^[0-9]+$ ]] || [ "$SPEED_PERCENT" -gt 100 ]; then
      echo "Error: speed must be 0-100" >&2
      exit 1
    fi
    ;;
esac

resolve_node
echo "Setting fan on node ${NODE} to ${SPEED_PERCENT}%..."

cleanup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trap 'cleanup' EXIT

kubectl create configmap "$CM_NAME" -n "$NAMESPACE" \
  --from-file=fan.py="${SCRIPT_DIR}/rpi5-fan.py" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl run "$POD_NAME" \
  --namespace="$NAMESPACE" \
  --image=python:3.12-slim \
  --restart=Never \
  --overrides="$(cat <<EOF
{
  "spec": {
    "nodeName": "${NODE}",
    "containers": [{
      "name": "fan-ctl",
      "image": "python:3.12-slim",
      "command": ["python3", "/scripts/fan.py", "${SPEED_PERCENT}"],
      "env": [{"name": "RP1_RESOURCE1", "value": "${RP1_PCI}"}],
      "securityContext": {"privileged": true},
      "volumeMounts": [
        {"name": "sys", "mountPath": "/host-sys"},
        {"name": "scripts", "mountPath": "/scripts"}
      ]
    }],
    "volumes": [
      {"name": "sys", "hostPath": {"path": "/sys"}},
      {"name": "scripts", "configMap": {"name": "${CM_NAME}"}}
    ]
  }
}
EOF
)" >/dev/null

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${POD_NAME}" -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1 || true
kubectl logs "$POD_NAME" -n "$NAMESPACE" 2>/dev/null || {
  kubectl describe pod "$POD_NAME" -n "$NAMESPACE" >&2
  exit 1
}
