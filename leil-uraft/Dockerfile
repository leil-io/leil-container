ARG BASE_IMAGE=leil-base:ubuntu-24.04
FROM ${BASE_IMAGE}

# Allow version pinning: --build-arg LEILFS_VERSION=5.8.0-1
ARG LEILFS_VERSION=""
LABEL io.leil.leilfs.version="${LEILFS_VERSION}"
RUN apt-get update && \
	if [ -z "$LEILFS_VERSION" ]; then \
		apt-get install -y saunafs-master saunafs-uraft saunafs-adm; \
	else \
		apt-get install -y saunafs-master="$LEILFS_VERSION" \
			saunafs-uraft="$LEILFS_VERSION" saunafs-adm="$LEILFS_VERSION"; \
	fi && \
	# Tools leil-uraft-helper calls without declaring them as dependencies,
	# plus busybox syslogd, as uraft and the helper only log through syslog
	apt-get install -y --no-install-recommends \
		iproute2 iputils-arping procps psmisc sudo busybox-static && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*

# Define a non-volume-mapped path for templates
ENV SAUNAFS_TEMPLATE_DIR=/opt/saunafs/templates

RUN mkdir -p ${SAUNAFS_TEMPLATE_DIR} && \
	cp /var/lib/saunafs/metadata.sfs.empty ${SAUNAFS_TEMPLATE_DIR}/metadata.sfs.empty

COPY leil-uraft.start.sh /leil-uraft.start.sh
RUN chmod +x /leil-uraft.start.sh

EXPOSE 9419 9420 9421 9427/udp 9428

CMD ["/leil-uraft.start.sh"]
