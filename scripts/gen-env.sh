#!/usr/bin/env bash
# Cria infra/.env com segredos aleatorios e consistentes entre infra e apps.
#
# Os pares abaixo PRECISAM ter o mesmo valor (o servico autentica na infra com
# a credencial que a infra criou). Preencher a mao e o erro mais comum:
#   POSTGRES_PASSWORD     = DB_PASSWORD
#   RABBITMQ_DEFAULT_PASS = RABBITMQ_PASSWORD = RABBITMQ_PASS (video-processor)
#   MINIO_ROOT_PASSWORD   = STORAGE_SECRET_KEY
#   REDIS_PASSWORD        = SPRING_DATA_REDIS_PASSWORD
# Tambem gera PASSWORD_PEPPER, GRAFANA_ADMIN_PASSWORD e o par RSA dos JWT.
#
# Uso: ./scripts/gen-env.sh           # so cria se ainda nao existir .env
#      ./scripts/gen-env.sh --force   # recria tudo (dados ja gravados com as
#                                     # senhas antigas deixam de abrir)
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require openssl

ENV_FILE="${INFRA_DIR}/.env"
if [[ -f "${ENV_FILE}" && "${1:-}" != "--force" ]]; then
  log "${ENV_FILE} ja existe. Use --force para recriar."
  exit 0
fi

rand() { openssl rand -hex 24; }
PG="$(rand)"; RMQ="$(rand)"; MINIO="$(rand)"; REDIS="$(rand)"

cp "${INFRA_DIR}/.env.example" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

set_var() { # chave valor
  awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 {print k "=" v; next} {print}' \
    "${ENV_FILE}" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "${ENV_FILE}"
}

set_var POSTGRES_PASSWORD "${PG}"
set_var DB_PASSWORD "${PG}"
set_var RABBITMQ_DEFAULT_PASS "${RMQ}"
set_var RABBITMQ_PASSWORD "${RMQ}"
set_var RABBITMQ_PASS "${RMQ}"
set_var MINIO_ROOT_PASSWORD "${MINIO}"
set_var STORAGE_SECRET_KEY "${MINIO}"
set_var REDIS_PASSWORD "${REDIS}"
set_var SPRING_DATA_REDIS_PASSWORD "${REDIS}"
set_var PASSWORD_PEPPER "$(rand)"
set_var GRAFANA_ADMIN_PASSWORD "$(openssl rand -hex 12)"
chmod 600 "${ENV_FILE}"

"${INFRA_DIR}/scripts/gen-jwt-keys.sh" --force >/dev/null

if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=CHANGE_ME' "${ENV_FILE}"; then
  die "sobrou CHANGE_ME em ${ENV_FILE}: $(grep -E '^[A-Za-z_]+=CHANGE_ME' "${ENV_FILE}" | cut -d= -f1 | tr '\n' ' ')"
fi
log "${ENV_FILE} criado com segredos aleatorios (perm 600)."
log "Grafana: admin / $(grep '^GRAFANA_ADMIN_PASSWORD=' "${ENV_FILE}" | cut -d= -f2)"
