#!/usr/bin/env bash
# Vars e helpers comuns aos scripts da infra. Não executa nada sozinho.
set -euo pipefail

CLUSTER="${CLUSTER:-fiapx}"
NAMESPACE="${NAMESPACE:-fiapx}"

# Raiz do repo infra/ (um nível acima de scripts/).
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Raiz do workspace (contém auth-service/, video-service/, video-processor/, infra/).
WORKSPACE_DIR="$(cd "${INFRA_DIR}/.." && pwd)"

# Serviço  ->  contexto de build (diretório do repo)  ->  imagem
SERVICES=(auth-service video-service video-processor)
image_for() { echo "ghcr.io/hackaton-fiap-x/$1:local"; }

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
  if grep -q 'CHANGE_ME' "${env_file}"; then
    die "Preencha os valores CHANGE_ME em ${INFRA_DIR}/.env (copie de .env.example) e rode de novo."
  fi
}
