
ARG BASE_IMAGE=leil-base:ubuntu-24.04
FROM ${BASE_IMAGE}

# Allow version pinning: --build-arg SAUNAFS_VERSION=5.8.0-1
ARG SAUNAFS_VERSION=""
RUN apt-get update && \
	if [ -z "$SAUNAFS_VERSION" ]; then \
		apt-get install -y saunafs-master; \
	else \
		apt-get install -y saunafs-master="$SAUNAFS_VERSION"; \
	fi && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*

# Define a non-volume-mapped path for templates
ENV SAUNAFS_TEMPLATE_DIR=/opt/saunafs/templates

RUN mkdir -p ${SAUNAFS_TEMPLATE_DIR} && \
	cp /var/lib/saunafs/metadata.sfs.empty ${SAUNAFS_TEMPLATE_DIR}/metadata.sfs.empty

COPY leil-master.start.sh /leil-master.start.sh
RUN chmod +x /leil-master.start.sh

EXPOSE 9419 9420 9421

CMD ["/leil-master.start.sh"]
