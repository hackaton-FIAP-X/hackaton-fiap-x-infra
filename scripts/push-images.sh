#!/usr/bin/env bash
# Publica as imagens :local ja construidas no registry IMAGE_REGISTRY (GHCR por
# padrao; ECR na AWS: IMAGE_REGISTRY=<conta>.dkr.ecr.<regiao>.amazonaws.com/fiapx).
#
# Uso: ./scripts/push-images.sh <tag> [<tag> ...]
#      ex.: ./scripts/push-images.sh "$GITHUB_SHA" latest
# Requer `docker login` no registry feito antes.
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require docker
(( $# > 0 )) || die "uso: $0 <tag> [<tag> ...]"

for svc in "${SERVICES[@]}"; do
  # origem: a imagem :local do build, qualquer que seja o registry de destino
  src="${LOCAL_IMAGE_REGISTRY}/${svc}:local"
  docker image inspect "${src}" >/dev/null 2>&1 || die "imagem ${src} nao existe. Rode build-images.sh antes."
  for tag in "$@"; do
    dst="$(IMAGE_TAG="${tag}" image_for "${svc}")"
    docker tag "${src}" "${dst}"
    log "push ${dst}"
    docker push "${dst}"
  done
done
