#!/usr/bin/env bash
# Checa os critérios de aceite de PLT-1, PLT-2, PLT-3 e PLT-7, e faz um smoke
# test do auth-service (AUTH-2..AUTH-6) pelo Ingress.
# Pré-condição: kind-up + deploy-infra + deploy-apps já rodaram.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl
fail=0
# local: infra de apoio roda no cluster (kind). aws: Postgres, RabbitMQ, Redis e
# S3 sao gerenciados, entao as checagens de StatefulSet/PVC/DNS/MinIO nao se aplicam.
TARGET="${VERIFY_TARGET:-local}"
check() { if eval "$2"; then log "OK  - $1"; else warn "FALHOU - $1"; fail=1; fi; }

# porta HTTP de cada serviço
port_for() { case "$1" in
  auth-service) echo 8080 ;; video-service) echo 8081 ;; video-processor) echo 8082 ;;
esac; }

if [[ "${TARGET}" == "local" ]]; then
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
# checa o bucket, nao o Job: o Job e apagado pelo ttlSecondsAfterFinished
check "bucket fiapx existe no MinIO" \
  "kubectl -n ${NAMESPACE} exec minio-0 -- test -d /data/fiapx"

log "== PLT-2: DNS interno do cluster =="
POD="$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=video-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${POD}" ]]; then
  check "video-service resolve postgres e rabbitmq pelo DNS do cluster" \
    "kubectl -n ${NAMESPACE} exec ${POD} -- sh -c 'getent hosts postgres.fiapx.svc.cluster.local && getent hosts rabbitmq.fiapx.svc.cluster.local' >/dev/null"
else
  warn "PULADO - pod do video-service ainda não existe"
fi
fi

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

# Na AWS e a URL do NLB; local, o Ingress do kind na porta 80.
BASE="${BASE_URL:-http://localhost}"

if kubectl -n "${NAMESPACE}" get ingress fiapx >/dev/null 2>&1; then
  check "Ingress roteia /auth e /videos" \
    "kubectl -n ${NAMESPACE} get ingress fiapx -o jsonpath='{.spec.rules[*].http.paths[*].path}' | grep -q '/auth' && kubectl -n ${NAMESPACE} get ingress fiapx -o jsonpath='{.spec.rules[*].http.paths[*].path}' | grep -q '/videos'"
  # /auth e repassado sem reescrever o prefixo, entao o actuator nao fica em
  # /auth/actuator; a JWKS publica e a rota mais barata para provar o roteamento.
  check "Ingress roteia ate o auth-service (GET /.well-known/jwks.json -> 200)" \
    "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 ${BASE}/.well-known/jwks.json)\" = 200 ]"
else
  warn "PULADO - Ingress não aplicado (rode ./scripts/deploy-ingress.sh)"
fi

log "== auth-service: register, login, JWKS e rate limit (via Ingress) =="
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

  # ---- E2E-1: upload -> worker -> ZIP (e video corrompido -> FAILED + DLQ) ----
  log "== E2E: video processado pelo worker =="
  FIXTURE="${INFRA_DIR}/k6/fixtures/sample-3s.mp4"
  json_field() { python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }
  upload() { # arquivo nome -> videoId
    curl -s --max-time 30 -X POST "${BASE}/videos" -H "Authorization: Bearer ${TOKEN}" \
      -F "file=@$1;filename=$2;type=video/mp4" | json_field videoId
  }
  await_final() { # videoId -> JSON final (COMPLETED/FAILED) ou vazio no timeout
    local id="$1" body status deadline=$(( SECONDS + ${E2E_TIMEOUT_S:-180} ))
    while (( SECONDS < deadline )); do
      body="$(curl -s --max-time 10 "${BASE}/videos/${id}" -H "Authorization: Bearer ${TOKEN}")"
      status="$(echo "${body}" | json_field status)"
      if [[ "${status}" == "COMPLETED" || "${status}" == "FAILED" ]]; then echo "${body}"; return; fi
      sleep 3
    done
  }

  OK_ID="$(upload "${FIXTURE}" e2e-ok.mp4)"
  BAD_FILE="$(mktemp)"; echo "isto nao e um video" > "${BAD_FILE}"
  BAD_ID="$(upload "${BAD_FILE}" e2e-corrompido.mp4)"; rm -f "${BAD_FILE}"
  check "uploads aceitos (videoIds ${OK_ID:-?} / ${BAD_ID:-?})" "[ -n '${OK_ID}' ] && [ -n '${BAD_ID}' ]"

  if [[ -n "${OK_ID}" ]]; then
    FINAL="$(await_final "${OK_ID}")"
    check "video valido chega a COMPLETED" "echo '${FINAL}' | grep -q '\"status\":\"COMPLETED\"'"
    FRAMES="$(echo "${FINAL}" | json_field frameCount)"
    check "ZIP tem frames (frameCount=${FRAMES:-0})" "[ '${FRAMES:-0}' -ge 1 ] 2>/dev/null"
    LOCATION="$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 10 "${BASE}/videos/${OK_ID}/zip" \
      -H "Authorization: Bearer ${TOKEN}")"
    check "GET /videos/{id}/zip redireciona para a URL pre-assinada do ZIP" \
      "echo '${LOCATION}' | grep -q '${OK_ID}.zip'"
    if kubectl -n "${NAMESPACE}" get pod minio-0 >/dev/null 2>&1; then
      check "ZIP gravado no MinIO" \
        "kubectl -n ${NAMESPACE} exec minio-0 -- sh -c 'ls -d /data/fiapx/fiapx/outputs/*/${OK_ID}.zip' >/dev/null"
    fi
  fi

  if [[ -n "${BAD_ID}" ]]; then
    FINAL="$(await_final "${BAD_ID}")"
    check "video corrompido chega a FAILED com INVALID_VIDEO" \
      "echo '${FINAL}' | grep -q '\"status\":\"FAILED\"' && echo '${FINAL}' | grep -q 'INVALID_VIDEO'"
    # PLT-8: o dono recebe o aviso de falha por e-mail (Mailhog no cluster)
    MAIL_FOUND=""
    for _ in $(seq 1 20); do
      MAIL_FOUND="$(kubectl -n "${NAMESPACE}" exec deploy/mailhog -- \
        wget -qO- "http://localhost:8025/api/v2/search?kind=containing&query=${BAD_ID}" 2>/dev/null \
        | grep -c "${BAD_ID}" || true)"
      [[ "${MAIL_FOUND:-0}" -ge 1 ]] && break
      sleep 2
    done
    check "e-mail de falha entregue ao dono no Mailhog (PLT-8)" "[ '${MAIL_FOUND:-0}' -ge 1 ] 2>/dev/null"
    if kubectl -n "${NAMESPACE}" get pod rabbitmq-0 >/dev/null 2>&1; then
      DLQ="$(kubectl -n "${NAMESPACE}" exec rabbitmq-0 -- rabbitmqctl -q list_queues name messages 2>/dev/null \
        | awk '$1=="video.processing.dlq" {print $2}')"
      check "mensagem do video corrompido na DLQ (video.processing.dlq=${DLQ:-0})" "[ '${DLQ:-0}' -ge 1 ] 2>/dev/null"
    fi
  fi

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

if [[ "${TARGET}" == "local" ]]; then
log "== PLT-2: persistência do Postgres sobrevive a delete de pod =="
# marcador unico: o teste roda varias vezes sobre o mesmo volume
MARK="$(date +%s)${RANDOM}"
PGUSER="$(kubectl -n "${NAMESPACE}" get secret infra-credentials -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)"
kubectl -n "${NAMESPACE}" exec statefulset/postgres -- \
  psql -U "${PGUSER}" -d postgres -c \
  "CREATE TABLE IF NOT EXISTS plt2_probe(id bigint); INSERT INTO plt2_probe VALUES (${MARK});" >/dev/null 2>&1
kubectl -n "${NAMESPACE}" delete pod postgres-0 >/dev/null
kubectl -n "${NAMESPACE}" rollout status statefulset/postgres --timeout=180s >/dev/null
COUNT="$(kubectl -n "${NAMESPACE}" exec statefulset/postgres -- \
  psql -U "${PGUSER}" -d postgres -tAc "SELECT count(*) FROM plt2_probe WHERE id = ${MARK};" | tr -d '[:space:]')"
check "linha ainda presente após delete do pod (count=${COUNT})" "[ \"${COUNT}\" = 1 ]"

# Por ultimo porque e destrutivo: com o Postgres fora por alguns segundos, o
# readiness dos servicos (que inclui o banco) cai e o Ingress responde 503.
# Esperamos todos voltarem para nao deixar o cluster degradado.
for svc in "${SERVICES[@]}"; do
  kubectl -n "${NAMESPACE}" rollout status "deployment/${svc}" --timeout=180s >/dev/null || true
done
check "servicos voltaram a ficar prontos depois do Postgres reiniciar" \
  "for s in ${SERVICES[*]}; do [ \"\$(kubectl -n ${NAMESPACE} get deploy \$s -o jsonpath='{.status.readyReplicas}')\" = \"\$(kubectl -n ${NAMESPACE} get deploy \$s -o jsonpath='{.spec.replicas}')\" ] || exit 1; done"
fi

if [[ ${fail} -eq 0 ]]; then log "TUDO OK ✅"; else die "algumas checagens falharam ❌"; fi
