#!/usr/bin/env bash
# Constrói as imagens dos 3 serviços a partir dos repos irmãos no workspace.
# Tag: ghcr.io/hackaton-fiap-x/<svc>:local
#
# Usa Dockerfile.prod quando o serviço tem um (imagem multi-stage, não-root —
# ex.: AUTH-8); senão cai no Dockerfile padrão do repo.
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require docker

for svc in "${SERVICES[@]}"; do
  ctx="${WORKSPACE_DIR}/${svc}"
  if [[ -f "${ctx}/Dockerfile.prod" ]]; then
    dockerfile="${ctx}/Dockerfile.prod"
  elif [[ -f "${ctx}/Dockerfile" ]]; then
    dockerfile="${ctx}/Dockerfile"
  else
    die "nenhum Dockerfile em ${ctx}"
  fi
  img="$(image_for "${svc}")"
  log "build ${img}  ($(basename "${dockerfile}"))"
  docker build -f "${dockerfile}" -t "${img}" "${ctx}"
done

log "imagens construídas:"
docker images --filter=reference='ghcr.io/hackaton-fiap-x/*:local'
