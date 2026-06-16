#!/usr/bin/env bash
# Build Novu Docker images from source and push to GHCR.
# Run from the repo root:
#
#   # Build and push all images
#   GHCR_USERNAME=ajesh-bochdale IMAGE_TAG=custom ./scripts/build-push-ghcr.sh
#
#   # Build and push specific services only
#   GHCR_USERNAME=ajesh-bochdale IMAGE_TAG=custom ./scripts/build-push-ghcr.sh worker ws dashboard
#
# On the server, set these in docker/community/.env:
#   NOVU_API_IMAGE=ghcr.io/ajesh-bochdale/novu/api:custom
#   NOVU_WORKER_IMAGE=ghcr.io/ajesh-bochdale/novu/worker:custom
#   NOVU_WS_IMAGE=ghcr.io/ajesh-bochdale/novu/ws:custom
#   NOVU_DASHBOARD_IMAGE=ghcr.io/ajesh-bochdale/novu/dashboard:custom
set -euo pipefail

GHCR_USERNAME="${GHCR_USERNAME:?Set GHCR_USERNAME to your GitHub username or org}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
REGISTRY="ghcr.io/${GHCR_USERNAME}/novu"

# Services to build — defaults to all; override via arguments
ALL_SERVICES=(api worker ws dashboard)
SERVICES=("${@:-${ALL_SERVICES[@]}}")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log()  { printf "${GREEN}▸${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}▸${NC} %s\n" "$*"; }
error(){ printf "${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

[ -f "pnpm-workspace.yaml" ] || error "Run this script from the repo root"

log "Registry : ${REGISTRY}"
log "Tag      : ${IMAGE_TAG}"
log "Services : ${SERVICES[*]}"
echo ""

# The Dockerfiles for api/worker/ws expect dotenvcreate.mjs at src/dotenvcreate.mjs
# (same pattern as the CI deploy workflow). Copy before building, clean up on exit.
NEEDS_DOTENV=(api worker ws)
STAGED=()
cleanup() {
  for svc in "${STAGED[@]}"; do
    rm -f "apps/${svc}/src/dotenvcreate.mjs"
  done
}
trap cleanup EXIT

for svc in "${SERVICES[@]}"; do
  if [[ " ${NEEDS_DOTENV[*]} " == *" ${svc} "* ]]; then
    cp scripts/dotenvcreate.mjs "apps/${svc}/src/dotenvcreate.mjs"
    STAGED+=("${svc}")
  fi
done

build_and_push() {
  local svc="$1"
  local tag="${REGISTRY}/${svc}:${IMAGE_TAG}"

  case "$svc" in
    api|worker|ws)
      log "Building ${svc}..."
      pnpm --silent --workspace-root pnpm-context -- "apps/${svc}/Dockerfile" \
        | docker buildx build \
            --load \
            --build-arg "PACKAGE_PATH=apps/${svc}" \
            -t "${tag}" \
            -
      ;;
    dashboard)
      log "Building dashboard..."
      docker buildx build \
        --load \
        -f apps/dashboard/dockerfile \
        -t "${tag}" \
        .
      ;;
    *)
      error "Unknown service: ${svc}. Valid options: api worker ws dashboard"
      ;;
  esac

  log "Pushing ${svc}..."
  docker push "${tag}"
}

for svc in "${SERVICES[@]}"; do
  build_and_push "$svc"
done

echo ""
log "Done. Add these to your server's docker/community/.env:"
echo ""
for svc in "${SERVICES[@]}"; do
  KEY="NOVU_$(echo "${svc}" | tr '[:lower:]' '[:upper:]')_IMAGE"
  echo "  ${KEY}=${REGISTRY}/${svc}:${IMAGE_TAG}"
done
echo ""
