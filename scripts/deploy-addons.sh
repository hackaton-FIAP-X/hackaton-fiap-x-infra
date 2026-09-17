#!/usr/bin/env bash
# PLT-3 — add-ons do cluster: Ingress NGINX e metrics-server.
#
# O kind nao traz nenhum dos dois. O metrics-server precisa de
# --kubelet-insecure-tls porque os kubelets do kind usam certificado
# self-signed; sem isso o HPA fica com "unknown" e nunca escala.
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl

INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.11.3}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.7.2}"

log "instalando Ingress NGINX (${INGRESS_NGINX_VERSION})"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

log "instalando metrics-server (${METRICS_SERVER_VERSION})"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
# kubelet do kind usa certificado self-signed
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
  2>/dev/null || log "flag --kubelet-insecure-tls ja aplicada"

log "aguardando o controller do Ingress..."
kubectl -n ingress-nginx wait --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

log "aguardando o metrics-server..."
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

log "add-ons prontos."
log "  Ingress:        http://localhost/auth/*  e  http://localhost/videos"
log "  metrics-server: kubectl top pods -n ${NAMESPACE}"
