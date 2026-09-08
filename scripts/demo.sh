#!/usr/bin/env bash
# Abre os port-forwards da demo e imprime as URLs. Ctrl-C encerra todos.
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl

PIDS=()
cleanup() { log "encerrando port-forwards..."; for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

forward() { # svc porta_local:porta_remota rotulo
  kubectl -n "${NAMESPACE}" port-forward "svc/$1" "$2" >/dev/null 2>&1 &
  PIDS+=("$!")
  printf '  %-18s http://localhost:%s\n' "$3" "${2%%:*}"
}

log "abrindo port-forwards do namespace ${NAMESPACE}"
echo
forward auth-service    8080:8080  "auth-service"
forward video-service   8081:8081  "video-service"
forward video-processor 8082:8082  "video-processor"
forward rabbitmq        15672:15672 "RabbitMQ"
forward minio           9001:9001  "MinIO console"
forward mailhog         8025:8025  "Mailhog"
forward grafana         3000:3000  "Grafana"
forward prometheus      9090:9090  "Prometheus"
echo
log "health dos servicos: curl -s http://localhost:8080/actuator/health"
log "Ctrl-C para encerrar."
wait
