#!/usr/bin/env bash
# Constrói as imagens dos 3 serviços a partir dos repos irmãos no workspace.
# Tag: ghcr.io/hackaton-fiap-x/<svc>:local
#
# Usa Dockerfile.prod quando o serviço tem um (imagem multi-stage, não-root —
# ex.: AUTH-8); senão cai no Dockerfile padrão do repo.
#
# security-commons (AUTH-5): serviços que dependem dele resolvem o artefato no
# GitHub Packages, que exige token read:packages até para leitura — sem token o
# build quebra com 401. Quando o repo do auth-service está ao lado, compilamos o
# módulo localmente e o injetamos no cache Maven do build via --build-context,
# o mesmo que o `make security-commons` do video-service faz. O Dockerfile do
# serviço não é copiado: é derivado na hora, então nunca diverge do original.
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require docker

MAVEN_IMAGE="${MAVEN_IMAGE:-maven:3.9-eclipse-temurin-21}"
COMMONS_DIR="${WORKSPACE_DIR}/auth-service/security-commons"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

commons_repo=""   # repositório Maven com o security-commons instalado
build_commons() {
  [[ -n "${commons_repo}" ]] && return 0
  [[ -f "${COMMONS_DIR}/pom.xml" ]] || die "security-commons não encontrado em ${COMMONS_DIR} (clone o auth-service ao lado)"
  log "compilando security-commons de ${COMMONS_DIR}"
  mkdir -p "${TMP}/m2"
  docker run --rm \
    -v "${COMMONS_DIR}":/mod:ro -v "${TMP}/m2":/root/.m2 -w /tmp \
    "${MAVEN_IMAGE}" sh -c 'cp -r /mod /tmp/mod && cd /tmp/mod && mvn -B -q install -DskipTests -Dspotless.check.skip=true'
  # o container roda como root; devolve a posse para o build context ser legível
  docker run --rm -v "${TMP}/m2":/m2 alpine chown -R "$(id -u):$(id -g)" /m2
  commons_repo="${TMP}/m2/repository"
}

# Deriva um Dockerfile que copia o repositório local para o cache Maven logo
# após o primeiro WORKDIR (estágio de build).
derive_dockerfile() { # dockerfile_origem destino
  awk 'BEGIN{done=0} {print} /^WORKDIR/ && !done {print "COPY --from=m2repo . /root/.m2/repository/"; done=1}' "$1" > "$2"
  grep -q 'COPY --from=m2repo' "$2" || die "não achei WORKDIR em $1 para injetar o security-commons"
}

failed=()
for svc in "${SERVICES[@]}"; do
  ctx="${WORKSPACE_DIR}/${svc}"
  if [[ -f "${ctx}/Dockerfile.prod" ]]; then
    dockerfile="${ctx}/Dockerfile.prod"
  elif [[ -f "${ctx}/Dockerfile" ]]; then
    dockerfile="${ctx}/Dockerfile"
  else
    warn "nenhum Dockerfile em ${ctx}"; failed+=("${svc}"); continue
  fi
  img="$(image_for "${svc}")"
  extra=()
  if grep -q '<artifactId>security-commons</artifactId>' "${ctx}/pom.xml" 2>/dev/null; then
    build_commons
    derive_dockerfile "${dockerfile}" "${TMP}/${svc}.Dockerfile"
    dockerfile="${TMP}/${svc}.Dockerfile"
    extra=(--build-context "m2repo=${commons_repo}")
    log "build ${img}  (com security-commons local)"
  else
    log "build ${img}  ($(basename "${dockerfile}"))"
  fi
  if ! docker buildx build --load -f "${dockerfile}" "${extra[@]}" -t "${img}" "${ctx}"; then
    warn "falhou o build de ${svc}"; failed+=("${svc}")
  fi
done

log "imagens:"
docker images --filter=reference='ghcr.io/hackaton-fiap-x/*:local'
if (( ${#failed[@]} )); then die "builds com falha: ${failed[*]}"; fi
