#!/bin/bash
set -e


usage() {
  echo "Usage: $0 --leilfs-version <version> --distro <distro> [--hub-user <dockerhub-user>] [--channel <stable|staging|experimental>]"
  echo "Publishes each component image to its own Docker Hub repository."
  echo "If --hub-user is not provided, defaults to leilfs"
  echo "If --channel is not provided, defaults to stable"
  echo "Example: $0 --leilfs-version 5.11.0~rc1-1 --distro 22.04 --channel staging"
  exit 1
}

require_value() {
  if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
    echo "Error: $1 requires a non-empty argument." >&2
    usage
  fi
}

docker_tag_value() {
  local value="$1"
  value="${value//[^a-zA-Z0-9_.-]/-}"
  value="${value#[.-]}"
  echo "$value"
}

# Default Docker Hub user/org
HUB_USER="leilfs"
CHANNEL="stable"

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
    --channel)
      require_value "$@"
      CHANNEL="$2"
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

DOCKER_LEILFS_VERSION="$(docker_tag_value "$LEILFS_VERSION")"
if [[ -z "$DOCKER_LEILFS_VERSION" ]]; then
  echo "Error: --leilfs-version does not contain any Docker tag compatible characters." >&2
  usage
fi

if [[ "$DOCKER_LEILFS_VERSION" != "$LEILFS_VERSION" ]]; then
  echo "Using LeilFS package version '$LEILFS_VERSION' and Docker tag version '$DOCKER_LEILFS_VERSION'."
fi

CHANNEL="$(echo "$CHANNEL" | xargs)"
if [[ "$CHANNEL" != "stable" && "$CHANNEL" != "staging" && "$CHANNEL" != "experimental" ]]; then
  echo "Error: --channel must be one of: stable, staging, experimental." >&2
  usage
fi

# Docker Hub login if credentials are present
if [[ -n "$DOCKER_USER" && -n "$DOCKER_PASS" ]]; then
  printf "%s\n" "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
fi

build_channel() {
  local channel="$1"
  local tag_suffix
  local base_image
  local leilfs_repository

  case "$channel" in
    stable)
      tag_suffix="ubuntu-$DISTRO"
      base_image="leil-base:ubuntu-$DISTRO"
      leilfs_repository="saunafs-ubuntu-$DISTRO"
      ;;
    staging)
      tag_suffix="staging-ubuntu-$DISTRO"
      base_image="leil-base:staging-ubuntu-$DISTRO"
      leilfs_repository="saunafs-ubuntu-$DISTRO-staging"
      ;;
    experimental)
      tag_suffix="experimental-ubuntu-$DISTRO"
      base_image="leil-base:experimental-ubuntu-$DISTRO"
      leilfs_repository="saunafs-ubuntu-$DISTRO-experimental"
      ;;
    *)
      echo "Error: unsupported channel '$channel'. Supported channels: stable, staging, experimental." >&2
      exit 1
      ;;
  esac

  # 1. Build base image

  echo "Building $channel base image: $base_image"
  docker build \
    -t "$base_image" \
    --build-arg BASE_IMAGE="ubuntu:$DISTRO" \
    --build-arg LEILFS_REPOSITORY="$leilfs_repository" \
    ./leil-base

  # 2. Build and tag all component images

  echo "Building $channel component images with LeilFS version $LEILFS_VERSION and distro $DISTRO"
  LEILFS_VERSION="$DOCKER_LEILFS_VERSION" TAG_SUFFIX="$tag_suffix" BASE_IMAGE="$base_image" docker compose build --build-arg LEILFS_VERSION="$LEILFS_VERSION"

  # 3. Push all images to Docker Hub
  for component in master metalogger cgiserver chunkserver client; do
    IMAGE="leil-$component:$DOCKER_LEILFS_VERSION-$tag_suffix"
    REMOTE_IMAGE="$HUB_USER/leil-$component:$DOCKER_LEILFS_VERSION-$tag_suffix"
    echo "Tagging $IMAGE as $REMOTE_IMAGE"
    docker tag "$IMAGE" "$REMOTE_IMAGE"
    echo "Pushing $REMOTE_IMAGE"
    docker push "$REMOTE_IMAGE"
  done
}

build_channel "$CHANNEL"

echo "Done."
