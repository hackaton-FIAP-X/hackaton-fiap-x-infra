#!/usr/bin/env bash
# PLT-3 — aplica o Ingress da aplicacao (requer deploy-addons.sh e deploy-apps.sh).
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl curl

BASE_URL="${BASE_URL:-http://localhost}"
TIMEOUT_S="${INGRESS_TIMEOUT_S:-180}"

if ! kubectl get ingressclass nginx >/dev/null 2>&1; then
  die "IngressClass 'nginx' nao existe. Rode ./scripts/deploy-addons.sh antes."
fi

kubectl apply -k "${INFRA_DIR}/k8s/ingress/overlays/local"

# `kubectl apply` volta antes de o controller NGINX carregar as regras; nesse
# intervalo ele responde 404 pelo backend padrao. So termina quando uma rota da
# aplicacao responde de verdade — senao quem vem depois (verify.sh, k6) falha
# por corrida. No CD isso ja aconteceu: Ingress criado e testado 3s depois.
log "aguardando o Ingress rotear ${BASE_URL}/.well-known/jwks.json ..."
deadline=$(( SECONDS + TIMEOUT_S ))
code=""
until [[ "${code}" == "200" ]]; do
  if (( SECONDS >= deadline )); then
    kubectl -n "${NAMESPACE}" describe ingress fiapx | tail -20 || true
    die "Ingress nao roteou em ${TIMEOUT_S}s (ultimo HTTP ${code:-sem resposta})"
  fi
  sleep 2
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${BASE_URL}/.well-known/jwks.json" || true)"
done

kubectl -n "${NAMESPACE}" get ingress
log "Ingress roteando (levou $(( TIMEOUT_S - (deadline - SECONDS) ))s)."
log "teste:  curl -s ${BASE_URL}/.well-known/jwks.json"
