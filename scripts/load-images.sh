#!/usr/bin/env bash
# Carrega as imagens locais para dentro do cluster kind (sem registry).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kind docker

for svc in "${SERVICES[@]}"; do
  img="$(image_for "${svc}")"
  docker image inspect "${img}" >/dev/null 2>&1 || die "imagem ${img} não existe. Rode scripts/build-images.sh antes."
  log "kind load ${img}"
  kind load docker-image "${img}" --name "${CLUSTER}"
done

log "imagens disponíveis no cluster '${CLUSTER}'."
