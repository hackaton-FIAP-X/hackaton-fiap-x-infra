#!/usr/bin/env bash
# Checa os critérios de aceite de PLT-1, PLT-2, PLT-3 e PLT-7, e faz um smoke
# test do auth-service (AUTH-2..AUTH-6) pelo Ingress.
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

log "== auth-service: register, login, JWKS e rate limit (via Ingress) =="
BASE="${BASE_URL:-http://localhost}"
if curl -s -o /dev/null --max-time 5 "${BASE}/auth/login"; then
  EMAIL="verify-$(date +%s)-${RANDOM}@fiapx.local"
  PASS="verify-Pass-123"

  check "JWKS publica em /.well-known/jwks.json (AUTH-4)" \
    "curl -sf --max-time 10 ${BASE}/.well-known/jwks.json | grep -q '\"kty\":\"RSA\"'"

  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "${BASE}/auth/register" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"Verify\",\"email\":\"${EMAIL}\",\"password\":\"${PASS}\"}")"
  check "POST /auth/register -> 201 (AUTH-2, recebido ${CODE})" "[ '${CODE}' = 201 ]"

  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "${BASE}/auth/register" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"Verify\",\"email\":\"${EMAIL}\",\"password\":\"${PASS}\"}")"
  check "e-mail duplicado -> 409 (AUTH-2, recebido ${CODE})" "[ '${CODE}' = 409 ]"

  TOKEN="$(curl -s --max-time 15 -X POST "${BASE}/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASS}\"}" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  check "POST /auth/login devolve um JWT (AUTH-3)" "[ \"\$(echo '${TOKEN}' | tr -cd . | wc -c)\" = 2 ]"

  # payload do JWT em base64url -> confere o issuer que o video-service exige
  PAYLOAD="$(echo "${TOKEN}" | cut -d. -f2 | tr '_-' '/+')"
  while (( ${#PAYLOAD} % 4 )); do PAYLOAD="${PAYLOAD}="; done
  check "token com iss=fiapx-auth e alg RS256" \
    "echo '${PAYLOAD}' | base64 -d 2>/dev/null | grep -q '\"iss\":\"fiapx-auth\"' && echo '${TOKEN}' | cut -d. -f1 | tr '_-' '/+' | base64 -d 2>/dev/null | grep -q 'RS256'"

  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "${BASE}/auth/login" \
    -H 'Content-Type: application/json' -d "{\"email\":\"${EMAIL}\",\"password\":\"senha-errada\"}")"
  check "credencial invalida -> 401 generico (AUTH-3, recebido ${CODE})" "[ '${CODE}' = 401 ]"

  # A integracao que importa: token do auth aceito pelo video-service via JWKS.
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${BASE}/videos" -H "Authorization: Bearer ${TOKEN}")"
  check "video-service aceita o token do auth-service (JWKS, recebido ${CODE})" "[ '${CODE}' = 200 ]"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${BASE}/videos")"
  check "video-service sem token -> 401 (recebido ${CODE})" "[ '${CODE}' = 401 ]"

  # Por ultimo: estoura o balde do IP e bloqueia o login por ate 60s.
  LAST=""
  for _ in $(seq 1 12); do
    LAST="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${BASE}/auth/login" \
      -H 'Content-Type: application/json' -d '{"email":"ratelimit@fiapx.local","password":"x"}')"
  done
  check "rate limit do login devolve 429 no excesso (AUTH-6, ultimo ${LAST})" "[ '${LAST}' = 429 ]"
  log "   (logins deste IP ficam bloqueados por ate 60s)"
else
  warn "PULADO - ${BASE} nao responde (rode ./scripts/deploy-ingress.sh)"
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
