#!/bin/bash
set -e


usage() {
  echo "Usage: $0 --leilfs-version <version> --distro <distro> [--hub-user <dockerhub-user>]"
  echo "Publishes each component image to its own Docker Hub repository."
  echo "If --hub-user is not provided, defaults to leilfs"
  echo "Example: $0 --leilfs-version 5.8.0-1 --distro 24.04"
  exit 1
}

require_value() {
  if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
    echo "Error: $1 requires a non-empty argument." >&2
    usage
  fi
}

# Default Docker Hub user/org
HUB_USER="leilfs"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --leilfs-version)
      require_value "$@"
      LEILFS_VERSION="$2"
      shift 2
      ;;
    --distro)
      require_value "$@"
      DISTRO="$2"
      shift 2
      ;;
    --hub-user)
      require_value "$@"
      HUB_USER="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z "$LEILFS_VERSION" || -z "$DISTRO" ]]; then
  usage
fi

TAG_SUFFIX="ubuntu-$DISTRO"
BASE_IMAGE="leil-base:ubuntu-$DISTRO"

# Docker Hub login if credentials are present
if [[ -n "$DOCKER_USER" && -n "$DOCKER_PASS" ]]; then
  printf "%s\n" "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
fi

# 1. Build base image

echo "Building base image: $BASE_IMAGE"
docker build -t "$BASE_IMAGE" --build-arg BASE_IMAGE="ubuntu:$DISTRO" ./leil-base

# 2. Build and tag all component images

echo "Building all component images with LeilFS version $LEILFS_VERSION and distro $DISTRO"
LEILFS_VERSION="$LEILFS_VERSION" TAG_SUFFIX="$TAG_SUFFIX" BASE_IMAGE="$BASE_IMAGE" docker compose build


# 3. Push all images to Docker Hub
for component in master metalogger cgiserver chunkserver client; do
  IMAGE="leil-$component:$LEILFS_VERSION-$TAG_SUFFIX"
  REMOTE_IMAGE="$HUB_USER/leil-$component:$LEILFS_VERSION-$TAG_SUFFIX"
  echo "Tagging $IMAGE as $REMOTE_IMAGE"
  docker tag "$IMAGE" "$REMOTE_IMAGE"
  echo "Pushing $REMOTE_IMAGE"
  docker push "$REMOTE_IMAGE"
done

echo "Done."
