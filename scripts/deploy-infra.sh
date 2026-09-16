#!/usr/bin/env bash
# Aplica a infra de apoio (PLT-2) e espera ficar pronta.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl

OVERLAY="${INFRA_DIR}/k8s/infra/overlays/local"
ensure_env "${OVERLAY}"

kubectl apply -f "${INFRA_DIR}/k8s/namespace.yaml"
# O template de um Job e imutavel: reaplicar depois de qualquer mudanca nele
# falha com "field is immutable". O Job e idempotente (mc mb --ignore-existing),
# entao recriar a cada deploy e seguro.
kubectl -n "${NAMESPACE}" delete job minio-createbuckets --ignore-not-found
log "aplicando ${OVERLAY}"
kubectl apply -k "${OVERLAY}"

# Um StatefulSet nao substitui sozinho um pod que nunca ficou Ready (ex.: preso
# em ImagePullBackOff por uma imagem errada ja corrigida). Recria esses pods para
# o rollout pegar o template novo.
for sts in postgres rabbitmq minio redis; do
  pod="${sts}-0"
  reason="$(kubectl -n "${NAMESPACE}" get pod "${pod}" \
    -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  if [[ "${reason}" == "ImagePullBackOff" || "${reason}" == "ErrImagePull" || "${reason}" == "CrashLoopBackOff" ]]; then
    warn "${pod} em ${reason}; recriando para aplicar o template atual"
    kubectl -n "${NAMESPACE}" delete pod "${pod}" --wait=false
  fi
done

log "aguardando StatefulSets (Postgres, RabbitMQ, MinIO, Redis)..."
for sts in postgres rabbitmq minio redis; do
  kubectl -n "${NAMESPACE}" rollout status "statefulset/${sts}" --timeout=300s
done
kubectl -n "${NAMESPACE}" rollout status deployment/mailhog --timeout=180s
kubectl -n "${NAMESPACE}" wait --for=condition=complete job/minio-createbuckets --timeout=180s

log "PVCs:"
kubectl -n "${NAMESPACE}" get pvc
log "pods:"
kubectl -n "${NAMESPACE}" get pods
