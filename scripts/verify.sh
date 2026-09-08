#!/usr/bin/env bash
# Checa os critérios de aceite de PLT-1, PLT-2, PLT-3 e PLT-7.
# Pré-condição: kind-up + deploy-infra + deploy-apps já rodaram.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl
fail=0
check() { if eval "$2"; then log "OK  - $1"; else warn "FALHOU - $1"; fail=1; fi; }

# porta HTTP de cada serviço
port_for() { case "$1" in
  auth-service) echo 8080 ;; video-service) echo 8081 ;; video-processor) echo 8082 ;;
esac; }

log "== PLT-2: infra Running =="
for sts in postgres rabbitmq minio redis; do
  check "statefulset ${sts} pronto" \
    "[ \"\$(kubectl -n ${NAMESPACE} get sts ${sts} -o jsonpath='{.status.readyReplicas}')\" = 1 ]"
done
check "deployment mailhog pronto" \
  "[ \"\$(kubectl -n ${NAMESPACE} get deploy mailhog -o jsonpath='{.status.readyReplicas}')\" = 1 ]"

log "== PLT-2: PVCs Bound =="
check "todos os PVC Bound" \
  "! kubectl -n ${NAMESPACE} get pvc -o jsonpath='{.items[*].status.phase}' | tr ' ' '\n' | grep -qv Bound"

log "== PLT-2: buckets MinIO =="
check "job minio-createbuckets concluído" \
  "[ \"\$(kubectl -n ${NAMESPACE} get job minio-createbuckets -o jsonpath='{.status.succeeded}')\" = 1 ]"

log "== PLT-2: DNS interno do cluster =="
POD="$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=video-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${POD}" ]]; then
  check "video-service resolve postgres e rabbitmq pelo DNS do cluster" \
    "kubectl -n ${NAMESPACE} exec ${POD} -- sh -c 'getent hosts postgres.fiapx.svc.cluster.local && getent hosts rabbitmq.fiapx.svc.cluster.local' >/dev/null"
else
  warn "PULADO - pod do video-service ainda não existe"
fi

log "== PLT-2: persistência do Postgres sobrevive a delete de pod =="
PGUSER="$(kubectl -n "${NAMESPACE}" get secret infra-credentials -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)"
kubectl -n "${NAMESPACE}" exec statefulset/postgres -- \
  psql -U "${PGUSER}" -d authdb -c \
  "CREATE TABLE IF NOT EXISTS plt2_probe(id int); INSERT INTO plt2_probe VALUES (1);" >/dev/null
kubectl -n "${NAMESPACE}" delete pod postgres-0 >/dev/null
kubectl -n "${NAMESPACE}" rollout status statefulset/postgres --timeout=180s >/dev/null
COUNT="$(kubectl -n "${NAMESPACE}" exec statefulset/postgres -- \
  psql -U "${PGUSER}" -d authdb -tAc "SELECT count(*) FROM plt2_probe;" | tr -d '[:space:]')"
check "linha ainda presente após delete do pod (count=${COUNT})" "[ \"${COUNT}\" = 1 ]"

log "== PLT-1: serviços Running + health UP + sem restart =="
for svc in "${SERVICES[@]}"; do
  p="$(port_for "${svc}")"
  check "deployment ${svc}: todas as replicas prontas" \
    "[ \"\$(kubectl -n ${NAMESPACE} get deploy ${svc} -o jsonpath='{.status.readyReplicas}')\" = \"\$(kubectl -n ${NAMESPACE} get deploy ${svc} -o jsonpath='{.spec.replicas}')\" ]"
  check "${svc} /actuator/health = UP" \
    "kubectl -n ${NAMESPACE} exec deploy/${svc} -- wget -qO- http://localhost:${p}/actuator/health | grep -q '\"status\":\"UP\"'"
  check "${svc} sem restarts" \
    "[ \"\$(kubectl -n ${NAMESPACE} get pod -l app.kubernetes.io/name=${svc} -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')\" = 0 ]"
done

log "== PLT-3: replicas, HPA e Ingress =="
check "video-service com 2 replicas" \
  "[ \"\$(kubectl -n ${NAMESPACE} get deploy video-service -o jsonpath='{.spec.replicas}')\" = 2 ]"

if kubectl -n "${NAMESPACE}" get hpa video-processor >/dev/null 2>&1; then
  check "HPA do worker configurado 2-10 @ 70% CPU" \
    "[ \"\$(kubectl -n ${NAMESPACE} get hpa video-processor -o jsonpath='{.spec.minReplicas}-{.spec.maxReplicas}-{.spec.metrics[0].resource.target.averageUtilization}')\" = '2-10-70' ]"
  # Sem metrics-server o HPA fica com targets <unknown> e nunca escala.
  TARGETS="$(kubectl -n "${NAMESPACE}" get hpa video-processor -o jsonpath='{.status.currentMetrics}' 2>/dev/null || true)"
  if [[ -z "${TARGETS}" || "${TARGETS}" == "null" ]]; then
    warn "HPA ainda sem métricas — metrics-server pode não estar pronto (./scripts/deploy-addons.sh)"
  else
    log "OK  - HPA está lendo métricas de CPU"
  fi
else
  warn "PULADO - HPA não aplicado (rode ./scripts/deploy-apps.sh)"
fi

if kubectl -n "${NAMESPACE}" get ingress fiapx >/dev/null 2>&1; then
  check "Ingress roteia /auth e /videos" \
    "kubectl -n ${NAMESPACE} get ingress fiapx -o jsonpath='{.spec.rules[*].http.paths[*].path}' | grep -q '/auth' && kubectl -n ${NAMESPACE} get ingress fiapx -o jsonpath='{.spec.rules[*].http.paths[*].path}' | grep -q '/videos'"
  check "Ingress responde em http://localhost/auth/actuator/health" \
    "curl -sf --max-time 10 http://localhost/auth/actuator/health | grep -q '\"status\":\"UP\"'"
else
  warn "PULADO - Ingress não aplicado (rode ./scripts/deploy-ingress.sh)"
fi

log "== PLT-7: Prometheus e Grafana =="
if kubectl -n "${NAMESPACE}" get deploy prometheus >/dev/null 2>&1; then
  check "prometheus pronto" \
    "[ \"\$(kubectl -n ${NAMESPACE} get deploy prometheus -o jsonpath='{.status.readyReplicas}')\" = 1 ]"
  check "grafana pronto" \
    "[ \"\$(kubectl -n ${NAMESPACE} get deploy grafana -o jsonpath='{.status.readyReplicas}')\" = 1 ]"
  # Todos os alvos anotados devem estar "up" no Prometheus.
  check "Prometheus está raspando os alvos anotados" \
    "kubectl -n ${NAMESPACE} exec deploy/prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=up{job=\"kubernetes-pods\"}' | grep -q '\"status\":\"success\"'"
  check "dashboard provisionado no Grafana" \
    "kubectl -n ${NAMESPACE} get configmap grafana-dashboards -o jsonpath='{.data}' | grep -q 'fiapx-overview'"
else
  warn "PULADO - observabilidade não aplicada (rode ./scripts/deploy-observability.sh)"
fi

if [[ ${fail} -eq 0 ]]; then log "TUDO OK ✅"; else die "algumas checagens falharam ❌"; fi
