#!/usr/bin/env bash
# Demonstracao de escalabilidade (APR): dispara N uploads simultaneos contra o
# ambiente AWS e mostra, no fim, o HPA subindo e o resultado do k6 — tudo num
# comando so, para a gravacao nao depender de digitar certo ao vivo.
#
# Uso:  ./scripts/demo-carga.sh            # 50 uploads (cenario do enunciado)
#       UPLOADS=300 ./scripts/demo-carga.sh
#       RESET=0 ./scripts/demo-carga.sh    # nao espera o HPA voltar ao minimo
#
# Painel ao vivo (opcional, em outro terminal):
#       watch -n2 kubectl -n fiapx get hpa
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl aws

UPLOADS="${UPLOADS:-50}"
RESET="${RESET:-1}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

K6="$(command -v k6 || true)"
[[ -z "${K6}" && -x "${HOME}/bin/k6" ]] && K6="${HOME}/bin/k6"
[[ -n "${K6}" ]] || die "k6 nao encontrado. Instale em ~/bin: curl -sSL https://github.com/grafana/k6/releases/download/v0.53.0/k6-v0.53.0-linux-amd64.tar.gz | tar xz --strip-components=1 -C ~/bin k6-v0.53.0-linux-amd64/k6"

banner() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }

# ------------------------------------------------------------------ preflight
aws sts get-caller-identity >/dev/null 2>&1 \
  || die "sessao AWS expirada. Abra o Learner Lab e rode 'aws configure' com as credenciais novas."
kubectl -n "${NAMESPACE}" get deploy video-processor >/dev/null 2>&1 \
  || aws eks update-kubeconfig --name "${CLUSTER:-fiapx}" >/dev/null

LB="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
[[ -n "${LB}" ]] || die "o Ingress nao tem endereco: o ambiente AWS esta no ar? (Actions -> AWS - ambiente -> up)"
API="http://${LB}"

replicas() { kubectl -n "${NAMESPACE}" get hpa "$1" -o jsonpath='{.status.currentReplicas}' 2>/dev/null; }

if [[ "${RESET}" == "1" ]]; then
  for _ in $(seq 1 60); do
    [[ "$(replicas video-processor)" == "2" && "$(replicas video-service)" == "2" ]] && break
    log "esperando o HPA voltar ao minimo (2 replicas) para a demo comecar do zero..."
    sleep 20
  done
fi

banner "AMBIENTE"
printf '  API .........: %s\n' "${API}"
printf '  Cluster .....: %s (%s nos)\n' "${CLUSTER:-fiapx}" "$(kubectl get nodes --no-headers | wc -l)"
kubectl -n "${NAMESPACE}" get hpa --no-headers | awk '{printf "  HPA %-16s %s replicas, alvo %s\n", $1, $6, $3}'

# ------------------------------------------------------- amostragem do HPA ---
SAMPLES="$(mktemp)"
trap 'rm -f "${SAMPLES}"' EXIT
(
  while :; do
    printf '%s %s %s\n' "$(date -u +%H:%M:%S)" "$(replicas video-service)" "$(replicas video-processor)" >> "${SAMPLES}"
    sleep 2
  done
) & SAMPLER=$!
trap 'kill "${SAMPLER}" 2>/dev/null || true; rm -f "${SAMPLES}"' EXIT

# ------------------------------------------------------------------- o pico --
banner "PICO: ${UPLOADS} UPLOADS SIMULTANEOS"
set +e
"${K6}" run --quiet \
  -e BASE_URL="${API}" -e UPLOADS="${UPLOADS}" \
  -e WAIT_FOR_PROCESSING=true -e PROCESSING_TIMEOUT_S=1200 \
  "${INFRA_DIR}/k6/upload-load-test.js"
RC=$?
set -e
kill "${SAMPLER}" 2>/dev/null || true

# --------------------------------------------------------------- resultado ---
banner "ESCALONAMENTO DURANTE O PICO"
printf '  %-10s %-16s %s\n' "horario" "video-service" "video-processor"
awk '{ if ($2 != vs || $3 != vp) { printf "  %-10s %-16s %s\n", $1, $2" replicas", $3" replicas"; vs=$2; vp=$3 } }' "${SAMPLES}"
printf '  pico: video-service %s replicas, video-processor %s replicas\n' \
  "$(awk 'BEGIN{m=0} {if ($2+0>m) m=$2} END{print m}' "${SAMPLES}")" \
  "$(awk 'BEGIN{m=0} {if ($3+0>m) m=$3} END{print m}' "${SAMPLES}")"

banner "FILAS"
kubectl -n "${NAMESPACE}" exec rabbitmq-0 -- rabbitmqctl -q list_queues name messages consumers 2>/dev/null \
  | awk 'NR==1 {printf "  %-24s %-10s %s\n", $1, $2, $3; next} {printf "  %-24s %-10s %s\n", $1, $2, $3}'

if [[ ${RC} -eq 0 ]]; then
  banner "RESULTADO: ${UPLOADS} enviados, ${UPLOADS} processados, 0 perdidos ✅"
else
  banner "RESULTADO: o k6 reprovou (codigo ${RC}) — veja as linhas requests_lost / uploads_rejected acima ❌"
fi
exit "${RC}"
