#!/usr/bin/env bash
# Sobe o cluster kind (idempotente).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kind kubectl

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  log "cluster '${CLUSTER}' já existe."
else
  log "criando cluster kind '${CLUSTER}'..."
  kind create cluster --config "${INFRA_DIR}/kind/kind-config.yaml"
fi

kubectl cluster-info --context "kind-${CLUSTER}"
log "aguardando os nos ficarem Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes
log "pronto. Contexto kubectl: kind-${CLUSTER}"
