#!/usr/bin/env bash
# Derruba o cluster kind. Apaga TODOS os volumes (dado local não persiste entre
# `down` e `up` — isso é esperado; ver infra/README.md).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kind

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  log "deletando cluster kind '${CLUSTER}'..."
  kind delete cluster --name "${CLUSTER}"
else
  log "cluster '${CLUSTER}' não existe — nada a fazer."
fi
