#!/usr/bin/env bash
# PLT-6 — publica no GHCR as imagens :local ja construidas, com a tag pedida.
#
# Uso: ./scripts/push-images.sh <tag> [<tag> ...]
#      ex.: ./scripts/push-images.sh "$GITHUB_SHA" latest
# Requer `docker login ghcr.io` feito antes.
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require docker
(( $# > 0 )) || die "uso: $0 <tag> [<tag> ...]"

for svc in "${SERVICES[@]}"; do
  src="$(IMAGE_TAG=local image_for "${svc}")"
  docker image inspect "${src}" >/dev/null 2>&1 || die "imagem ${src} nao existe. Rode build-images.sh antes."
  for tag in "$@"; do
    dst="$(IMAGE_TAG="${tag}" image_for "${svc}")"
    docker tag "${src}" "${dst}"
    log "push ${dst}"
    docker push "${dst}"
  done
done
