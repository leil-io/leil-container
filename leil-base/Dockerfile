ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}
ARG BASE_IMAGE
ARG LEILFS_REPOSITORY=""
ENV BASE_IMAGE=${BASE_IMAGE}
LABEL maintainer="hello@leil.io"

# Install required packages
# Ubuntu 24.10+ (including 26.04) no longer bundles /usr/local/sbin/unminimize in the
# base image; it must be installed from the "unminimize" apt package first.
RUN apt-get update && \
	apt-get install -y --no-install-recommends gnupg wget dirmngr util-linux dialog ca-certificates && \
	if ! command -v unminimize >/dev/null 2>&1; then \
		apt-get install -y --no-install-recommends unminimize; \
	fi && \
	yes | unminimize && \
	apt-get clean && rm -rf /var/lib/apt/lists/*

# Handle Ubuntu 26.04 special case for uutils coreutils
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    . /etc/os-release && \
    if [ "${ID}" = "ubuntu" ] && [ "${VERSION_ID}" = "26.04" ]; then \
        echo "Ubuntu 26.04 detected: reverting uutils coreutils to GNU" && \
        apt-get update && \
        apt-get -y install coreutils-from-gnu coreutils-from-uutils- --allow-remove-essential; \
    fi

# Ensure gnupg home exists before importing key
RUN mkdir -p /root/.gnupg

# Update CA certificates before running gpg
# The key is received into gpg's default keyring, then explicitly re-exported
# in raw OpenPGP binary format: writing directly into a --keyring target via
# --receive-keys instead produces GnuPG's internal "keybox" format on newer
# GnuPG versions, which apt's signed-by= rejects as an "unsupported filetype".
RUN update-ca-certificates && \
	gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "0xA80B96E2C79457D4" && \
	gpg --export "0xA80B96E2C79457D4" > /usr/share/keyrings/saunafs-archive-keyring.gpg

# Validate BASE_IMAGE and set LeilFS repo accordingly
RUN if [ "$BASE_IMAGE" = "ubuntu:22.04" ]; then \
      CODENAME=jammy; \
    elif [ "$BASE_IMAGE" = "ubuntu:24.04" ]; then \
      CODENAME=noble; \
    elif [ "$BASE_IMAGE" = "ubuntu:26.04" ]; then \
      CODENAME=resolute; \
    else \
      echo "ERROR: Only ubuntu:22.04, ubuntu:24.04, or ubuntu:26.04 are supported for now." && exit 1; \
    fi && \
    BASE_IMAGE_VERSION="${BASE_IMAGE#*:}" && \
    if [ -z "$LEILFS_REPOSITORY" ]; then \
      LEILFS_REPOSITORY="saunafs-ubuntu-$BASE_IMAGE_VERSION"; \
    fi && \
    case "$LEILFS_REPOSITORY" in \
      http://*|https://*) REPOSITORY_URL="$LEILFS_REPOSITORY" ;; \
      *) REPOSITORY_URL="https://repo.leil.io/repository/$LEILFS_REPOSITORY/" ;; \
    esac && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/saunafs-archive-keyring.gpg] $REPOSITORY_URL $CODENAME main" > /etc/apt/sources.list.d/saunafs.list
