#!/bin/bash
# Deploy Pi 5 fan CronJob (every 5 minutes, thermal auto speed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="${FAN_NODE:-${NODE:-}}"
NAMESPACE="${FAN_NAMESPACE:-kube-system}"
CM_NAME="${FAN_CM_NAME:-rpi5-fan-control-script}"

if [ -z "$NODE" ]; then
  NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
if [ -z "$NODE" ]; then
  echo "Set FAN_NODE or NODE (kubectl get nodes)." >&2
  exit 1
fi

echo "Deploying fan CronJob on node ${NODE} (every 5 minutes)..."

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true

kubectl create configmap "$CM_NAME" \
  --namespace="$NAMESPACE" \
  --from-file=fan.py="${ROOT}/scripts/rpi5-fan.py" \
  --dry-run=client -o yaml | kubectl apply -f -

sed "s/__FAN_NODE__/${NODE}/" "${ROOT}/scripts/rpi5-fan-cronjob.yaml" | kubectl apply -f -

echo "Done. Check: kubectl get cronjob,pods -n ${NAMESPACE} -l app=rpi5-fan-control"
echo "Logs:    kubectl logs -n ${NAMESPACE} -l app=rpi5-fan-control --tail=20"
