#!/usr/bin/env bash
# Vars e helpers comuns aos scripts da infra. Não executa nada sozinho.
set -euo pipefail

CLUSTER="${CLUSTER:-fiapx}"
NAMESPACE="${NAMESPACE:-fiapx}"

# Raiz do repo infra/ (um nível acima de scripts/).
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Raiz do workspace (contém auth-service/, video-service/, video-processor/, infra/).
# shellcheck disable=SC2034  # consumida pelos scripts que dão source neste arquivo
WORKSPACE_DIR="$(cd "${INFRA_DIR}/.." && pwd)"

# Serviço  ->  contexto de build (diretório do repo)  ->  imagem
# shellcheck disable=SC2034  # consumida pelos scripts que dão source neste arquivo
SERVICES=(auth-service video-service video-processor)
# Registry e tag sobrescreviveis (o CD usa o SHA do commit). O overlay local
# referencia :local, entao o default precisa continuar sendo esse.
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io/hackaton-fiap-x}"
IMAGE_TAG="${IMAGE_TAG:-local}"
image_for() { echo "${IMAGE_REGISTRY}/$1:${IMAGE_TAG}"; }

log()  { printf '\033[1;34m[infra]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[infra] AVISO:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[infra] ERRO:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' não encontrado no PATH. Veja infra/README.md (pré-requisitos)."
  done
}

# Garante que o .env do overlay existe e está preenchido.
# Fonte canônica: infra/.env (você preenche UMA vez). Se não existir, cai no
# .env.example. O arquivo do overlay é sempre uma cópia — os dois overlays
# (infra e apps) ficam com valores idênticos, que é o que a stack exige.
ensure_env() {
  local overlay_dir="$1"
  local env_file="${overlay_dir}/.env"
  local source_file="${INFRA_DIR}/.env"
  [[ -f "${source_file}" ]] || source_file="${INFRA_DIR}/.env.example"

  if [[ ! -f "${env_file}" || "${source_file}" -nt "${env_file}" ]]; then
    cp "${source_file}" "${env_file}"
    log "gerado ${env_file} a partir de $(basename "${source_file}")"
  fi
  # So valores (CHAVE=CHANGE_ME...); o cabecalho comentado do template tambem
  # cita CHANGE_ME e nao pode contar.
  if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=CHANGE_ME' "${env_file}"; then
    die "Ha valores CHANGE_ME em ${INFRA_DIR}/.env. Preencha as senhas e gere as chaves JWT com ./scripts/gen-jwt-keys.sh."
  fi
}
