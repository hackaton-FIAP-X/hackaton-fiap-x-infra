#!/usr/bin/env bash
# PLT-3 — aplica o Ingress da aplicacao (requer deploy-addons.sh e deploy-apps.sh).
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl

if ! kubectl get ingressclass nginx >/dev/null 2>&1; then
  die "IngressClass 'nginx' nao existe. Rode ./scripts/deploy-addons.sh antes."
fi

kubectl apply -k "${INFRA_DIR}/k8s/ingress/overlays/local"
kubectl -n "${NAMESPACE}" get ingress

log "teste:  curl -i http://localhost/auth/actuator/health"
