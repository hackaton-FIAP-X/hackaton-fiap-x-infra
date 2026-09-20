#!/usr/bin/env bash
# Painel de metricas do ambiente, em um comando — feito para a apresentacao:
# roda, tira print (ou grava a tela) e os numeros estao todos ali.
#
# Uso:  ./scripts/metricas.sh              # painel no terminal
#       ./scripts/metricas.sh --grafana    # tambem abre Grafana e Prometheus no navegador
#       JANELA=6h ./scripts/metricas.sh    # janela das taxas (default 1h)
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl python3 curl

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
JANELA="${JANELA:-1h}"
GRAFANA_MODE=0
[[ "${1:-}" == "--grafana" ]] && GRAFANA_MODE=1

titulo() { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
linha()  { printf '   %-34s \033[1m%s\033[0m\n' "$1" "$2"; }

kubectl -n "${NAMESPACE}" get deploy video-processor >/dev/null 2>&1 \
  || die "sem acesso ao cluster. Rode: aws eks update-kubeconfig --name ${CLUSTER:-fiapx}"

# Prometheus so responde dentro do cluster; o port-forward cai no fim do script.
PF_PORT="${PF_PORT:-19090}"
kubectl -n "${NAMESPACE}" port-forward svc/prometheus "${PF_PORT}:9090" >/dev/null 2>&1 &
PF_PID=$!
cleanup() { kill "${PF_PID}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
for _ in $(seq 1 20); do
  curl -sf "http://localhost:${PF_PORT}/-/ready" >/dev/null 2>&1 && break
  sleep 0.5
done

# consulta instantanea; devolve so o valor (ou "-")
prom() {
  curl -sG "http://localhost:${PF_PORT}/api/v1/query" --data-urlencode "query=$1" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)["data"]["result"]
except Exception:
    print("-"); sys.exit()
print(r[0]["value"][1] if r else "-")'
}

# consulta agrupada; devolve "rotulo=valor" por linha
prom_por() {
  curl -sG "http://localhost:${PF_PORT}/api/v1/query" --data-urlencode "query=$1" 2>/dev/null \
    | python3 -c '
import json, sys
rotulo = sys.argv[1]
try:
    r = json.load(sys.stdin)["data"]["result"]
except Exception:
    r = []
partes = [m["metric"].get(rotulo, "?") + "=" + m["value"][1] for m in r]
print(" ".join(partes) if partes else "nenhuma")' "$2"
}

num() { python3 -c "
import sys
v = sys.argv[1]
print('-' if v in ('-', '') else f'{float(v):,.0f}'.replace(',', '.'))" "$1"; }
seg() { python3 -c "
import sys
v = sys.argv[1]
print('-' if v in ('-', '') else f'{float(v):.2f} s'.replace('.', ','))" "$1"; }

LB="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo '-')"

printf '\n\033[1m FIAP X — PAINEL DO AMBIENTE\033[0m  (%s)\n' "$(date '+%d/%m/%Y %H:%M')"

titulo "AMBIENTE"
linha "API publica" "http://${LB}"
linha "Cluster" "$(kubectl config current-context | sed 's|.*/||') · $(kubectl get nodes --no-headers | wc -l) nos"
linha "Pods no ar" "$(kubectl -n "${NAMESPACE}" get pods --no-headers | grep -c Running)"
linha "Reinicios de pod" "$(kubectl -n "${NAMESPACE}" get pods --no-headers | awk '{s+=$4} END{print s+0}')"

titulo "ESCALA AUTOMATICA (HPA)"
kubectl -n "${NAMESPACE}" get hpa --no-headers \
  | awk '{printf "   %-34s \033[1m%s replicas (min %s, max %s) · CPU %s\033[0m\n", $1, $7, $5, $6, $4}'

titulo "PROCESSAMENTO DE VIDEO (Prometheus)"
linha "Videos processados" "$(num "$(prom 'sum(videos_processed_total)')")"
linha "Falhas por motivo" "$(prom_por 'sum by(error_code)(videos_failed_total)' error_code | tr '\n' ' ')"
linha "Tempo por video (p95)" "$(seg "$(prom "histogram_quantile(0.95, sum by(le)(rate(video_processing_seconds_bucket[${JANELA}])))")")"
linha "Tempo por video (mediana)" "$(seg "$(prom "histogram_quantile(0.50, sum by(le)(rate(video_processing_seconds_bucket[${JANELA}])))")")"
linha "Vazao (videos/min, ${JANELA})" "$(python3 -c "
import sys
v = sys.argv[1]
print('-' if v in ('-', '') else f'{float(v)*60:.1f}'.replace('.', ','))" "$(prom "sum(rate(videos_processed_total[${JANELA}]))")")"

titulo "FILAS (RabbitMQ)"
kubectl -n "${NAMESPACE}" exec rabbitmq-0 -- rabbitmqctl -q list_queues name messages consumers 2>/dev/null \
  | awk 'NR>1 {printf "   %-34s \033[1m%s mensagens · %s consumidores\033[0m\n", $1, $2, $3}'

titulo "ULTIMO TESTE DE CARGA (k6)"
python3 - "${INFRA_DIR}/docs/load" <<'PY'
import glob, json, os, sys
arquivos = sorted(glob.glob(os.path.join(sys.argv[1], "*-summary.json")))
if not arquivos:
    print("   nenhum relatorio em docs/load/ — rode ./scripts/demo-carga.sh")
    raise SystemExit
ultimo = arquivos[-1]
d = json.load(open(ultimo))
m = d.get("metrics", {})
def c(nome):
    v = m.get(nome, {}).get("values", m.get(nome, {}))
    return int(v.get("count", v.get("value", 0)) or 0)
p95 = m.get("http_req_duration", {}).get("values", {}).get("p(95)", 0) / 1000
enviados = c("uploads_accepted") + c("uploads_rejected")
for rotulo, valor in [
    ("Arquivo", os.path.basename(ultimo)),
    ("Uploads disparados juntos", f"{enviados}"),
    ("Aceitos / recusados", f"{c('uploads_accepted')} / {c('uploads_rejected')}"),
    ("Requisicoes perdidas", f"{c('requests_lost')}"),
    ("Nao processados", f"{c('videos_not_completed')}"),
    ("p95 do upload", f"{p95:.2f} s".replace(".", ",")),
]:
    print(f"   {rotulo:<34} \033[1m{valor}\033[0m")
PY

titulo "VERIFICACAO DE PONTA A PONTA"
linha "Relatorio completo" "docs/load/RELATORIO-aws-2026-09-20.md"
linha "Evidencias dos testes" "docs/load/evidencias/"

if [[ "${GRAFANA_MODE}" == "1" ]]; then
  titulo "OBSERVABILIDADE"
  kubectl -n "${NAMESPACE}" port-forward svc/grafana 3000:3000 >/dev/null 2>&1 &
  GF_PID=$!
  cleanup() { kill "${PF_PID}" "${GF_PID}" 2>/dev/null || true; }
  SENHA="$(kubectl -n "${NAMESPACE}" get secret infra-credentials \
    -o jsonpath='{.data.GRAFANA_ADMIN_PASSWORD}' | base64 -d)"
  linha "Grafana" "http://localhost:3000  (admin / ${SENHA})"
  linha "Dashboard" "FIAP X — visao geral"
  linha "Prometheus" "http://localhost:${PF_PORT}"
  printf '\n   \033[1mCtrl-C encerra os acessos.\033[0m\n\n'
  wait "${GF_PID}"
fi
echo
