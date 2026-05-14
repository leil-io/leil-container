
ARG BASE_IMAGE=leil-base:ubuntu-24.04
FROM ${BASE_IMAGE}

# Allow version pinning: --build-arg SAUNAFS_VERSION=5.8.0-1
ARG SAUNAFS_VERSION=""
RUN apt-get update && \
	if [ -z "$SAUNAFS_VERSION" ]; then \
		apt-get install -y saunafs-chunkserver; \
	else \
		apt-get install -y saunafs-chunkserver="$SAUNAFS_VERSION"; \
	fi && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*

COPY leil-chunkserver.start.sh /leil-chunkserver.start.sh
RUN chmod +x /leil-chunkserver.start.sh

EXPOSE 9422

CMD ["/leil-chunkserver.start.sh"]
