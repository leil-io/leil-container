ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}
ARG BASE_IMAGE
ARG LEILFS_REPOSITORY=""
ENV BASE_IMAGE=${BASE_IMAGE}
LABEL maintainer="hello@leil.io"

# Install required packages
RUN apt-get update && \
	apt-get install -y --no-install-recommends gnupg wget dirmngr util-linux dialog ca-certificates && \
	yes | unminimize && \
	apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure gnupg home exists before importing key
RUN mkdir -p /root/.gnupg

# Update CA certificates before running gpg
RUN update-ca-certificates && \
	gpg --no-default-keyring \
	--keyring /usr/share/keyrings/saunafs-archive-keyring.gpg \
	--keyserver hkps://keyserver.ubuntu.com \
	--receive-keys 0xA80B96E2C79457D4

# Validate BASE_IMAGE and set LeilFS repo accordingly
RUN if [ "$BASE_IMAGE" = "ubuntu:22.04" ]; then \
      CODENAME=jammy; \
    elif [ "$BASE_IMAGE" = "ubuntu:24.04" ]; then \
      CODENAME=noble; \
    else \
      echo "ERROR: Only ubuntu:22.04 or ubuntu:24.04 are supported for now." && exit 1; \
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
