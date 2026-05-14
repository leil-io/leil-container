#!/bin/bash
set -e


usage() {
  echo "Usage: $0 --leilfs-version <version> --distro <distro> [--registry <registry>]"
  echo "If --registry is not provided, defaults to registry.leil.io/public"
  echo "Example: $0 --leilfs-version 5.8.0-1 --distro 24.04"
  exit 1
}

# Default registry
REGISTRY="registry.leil.io/public"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --leilfs-version)
      SAUNAFS_VERSION="$2"
      shift 2
      ;;
    --distro)
      DISTRO="$2"
      shift 2
      ;;
    --registry)
      REGISTRY="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z "$SAUNAFS_VERSION" || -z "$DISTRO" ]]; then
  usage
fi

TAG_SUFFIX="ubuntu-$DISTRO"
BASE_IMAGE="leil-base:ubuntu-$DISTRO"

# Docker login if credentials are present
if [[ -n "$DOCKER_USER" && -n "$DOCKER_PASS" ]]; then
  printf "%s\n" "$DOCKER_PASS" | docker login "$REGISTRY" -u "$DOCKER_USER" --password-stdin
fi

# 1. Build base image

echo "Building base image: $BASE_IMAGE"
docker build -t "$BASE_IMAGE" --build-arg BASE_IMAGE="ubuntu:$DISTRO" ./leil-base

# 2. Build and tag all component images

echo "Building all component images with LeilFS version $SAUNAFS_VERSION and distro $DISTRO"
SAUNAFS_VERSION="$SAUNAFS_VERSION" TAG_SUFFIX="$TAG_SUFFIX" BASE_IMAGE="$BASE_IMAGE" docker compose build


# 3. Push all images to your registry
for component in master metalogger cgiserver chunkserver client; do
  IMAGE="leil-$component:$SAUNAFS_VERSION-$TAG_SUFFIX"
  REMOTE_IMAGE="$REGISTRY/leil-$component:$SAUNAFS_VERSION-$TAG_SUFFIX"
  echo "Tagging $IMAGE as $REMOTE_IMAGE"
  docker tag "$IMAGE" "$REMOTE_IMAGE"
  echo "Pushing $REMOTE_IMAGE"
  docker push "$REMOTE_IMAGE"
done

echo "Done."
