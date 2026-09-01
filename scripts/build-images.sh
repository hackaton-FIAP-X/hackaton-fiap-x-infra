#!/usr/bin/env bash
# Constrói as imagens dos 3 serviços a partir dos Dockerfiles existentes em
# cada repo do workspace. Tag: ghcr.io/hackaton-fiap-x/<svc>:local
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require docker

for svc in "${SERVICES[@]}"; do
  ctx="${WORKSPACE_DIR}/${svc}"
  [[ -f "${ctx}/Dockerfile" ]] || die "Dockerfile não encontrado em ${ctx}"
  img="$(image_for "${svc}")"
  log "build ${img}  (contexto: ${ctx})"
  docker build -t "${img}" "${ctx}"
done

log "imagens construídas:"
docker images --filter=reference='ghcr.io/hackaton-fiap-x/*:local'
