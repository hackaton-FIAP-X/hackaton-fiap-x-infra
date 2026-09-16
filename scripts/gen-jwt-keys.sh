#!/usr/bin/env bash
# Gera o par RSA dos JWT (AUTH-3/AUTH-4) e grava em infra/.env.
#
# Formato exigido pelo JwtKeyConfig do auth-service: Base64 de DER, uma linha,
# PKCS8 na chave privada e X509 (SubjectPublicKeyInfo) na pública. PEM não serve.
#
# Uso:  ./scripts/gen-jwt-keys.sh          # grava (cria .env a partir do template se preciso)
#       ./scripts/gen-jwt-keys.sh --force  # substitui um par já existente
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require openssl base64

ENV_FILE="${INFRA_DIR}/.env"
[[ -f "${ENV_FILE}" ]] || cp "${INFRA_DIR}/.env.example" "${ENV_FILE}"

if ! grep -q '^JWT_PRIVATE_KEY=CHANGE_ME' "${ENV_FILE}" && [[ "${1:-}" != "--force" ]]; then
  log "já existe um par de chaves em ${ENV_FILE}. Use --force para gerar outro"
  log "(tokens emitidos com o par antigo deixam de validar)."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${TMP}/private.pem" 2>/dev/null
PRIVATE_B64="$(openssl pkcs8 -topk8 -nocrypt -in "${TMP}/private.pem" -outform DER | base64 -w0)"
PUBLIC_B64="$(openssl pkey -in "${TMP}/private.pem" -pubout -outform DER | base64 -w0)"

set_var() { # chave valor
  local tmp="${ENV_FILE}.tmp"
  if grep -q "^$1=" "${ENV_FILE}"; then
    # awk evita problemas com / e + do base64 que um sed teria
    awk -v k="$1" -v v="$2" 'BEGIN{FS=OFS="="} $1==k {print k "=" v; next} {print}' "${ENV_FILE}" > "${tmp}"
    mv "${tmp}" "${ENV_FILE}"
  else
    printf '%s=%s\n' "$1" "$2" >> "${ENV_FILE}"
  fi
}

set_var JWT_PRIVATE_KEY "${PRIVATE_B64}"
set_var JWT_PUBLIC_KEY "${PUBLIC_B64}"
chmod 600 "${ENV_FILE}"

log "par RSA 2048 gravado em ${ENV_FILE} (JWT_PRIVATE_KEY / JWT_PUBLIC_KEY)."
log "rode ./scripts/deploy-apps.sh para levar ao cluster."
