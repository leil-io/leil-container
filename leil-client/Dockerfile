
ARG BASE_IMAGE=leil-base:ubuntu-24.04
FROM ${BASE_IMAGE}

# Allow version pinning: --build-arg LEILFS_VERSION=5.8.0-1
ARG LEILFS_VERSION=""
RUN apt-get update && \
	if [ -z "$LEILFS_VERSION" ]; then \
		apt-get install -y saunafs-client saunafs-adm; \
	else \
		apt-get install -y saunafs-client="$LEILFS_VERSION" saunafs-adm="$LEILFS_VERSION"; \
	fi && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*

COPY leil-client.start.sh leil-client.start.sh
RUN chmod +x leil-client.start.sh

ENTRYPOINT ["./leil-client.start.sh"]
