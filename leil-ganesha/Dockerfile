ARG BASE_IMAGE=leil-base:ubuntu-24.04

# Builds NFS-Ganesha from source, at the release the LeilFS FSAL is built
# against (ganesha-version.sh), as Ubuntu does not ship most of them.
FROM ${BASE_IMAGE} AS build

# Allow version pinning: --build-arg LEILFS_VERSION=5.8.0-1
ARG LEILFS_VERSION=""
# Overrides the release ganesha-version.sh picks; only for testing, as
# the FSAL does not load into any other
ARG GANESHA_VERSION=""

RUN apt-get update && \
	apt-get install -y --no-install-recommends \
		bison build-essential byacc cmake flex git pkg-config \
		libacl1-dev libblkid-dev libcap-dev libdbus-1-dev libjemalloc-dev \
		libnfsidmap-dev libnsl-dev libsqlite3-dev libssl-dev libtirpc-dev \
		liburcu-dev && \
	rm -rf /var/lib/apt/lists/*

COPY ganesha-version.sh /usr/local/bin/ganesha-version.sh

# The LeilFS version is resolved here, once, so the FSAL installed below is
# the one Ganesha is built for even if the repository changes meanwhile.
RUN apt-get update && \
	if [ -z "$LEILFS_VERSION" ]; then \
		LEILFS_VERSION="$(apt-cache madison saunafs-nfs-ganesha | awk 'NR == 1 {print $3}')"; \
	fi && \
	apt-cache madison saunafs-nfs-ganesha | awk '{print $3}' | grep -qxF -- "$LEILFS_VERSION" || \
		{ echo "ERROR: saunafs-nfs-ganesha $LEILFS_VERSION is not in the repository." >&2; exit 1; } && \
	echo "$LEILFS_VERSION" > /leilfs-version && \
	GANESHA="${GANESHA_VERSION:-$(bash /usr/local/bin/ganesha-version.sh "$LEILFS_VERSION")}" && \
	echo "$GANESHA" > /ganesha-version && \
	rm -rf /var/lib/apt/lists/*

# Ganesha before V15.4 does not build on Ubuntu 26.04 with -Werror (fixed
# upstream in bsd-base64.c).
RUN GANESHA="$(cat /ganesha-version)" && \
	git clone --depth 1 --recurse-submodules --shallow-submodules \
		--branch "V${GANESHA}" https://github.com/nfs-ganesha/nfs-ganesha.git /src && \
	. /etc/os-release && \
	if [ "$VERSION_ID" = 26.04 ] && dpkg --compare-versions "$GANESHA" lt 15.4; then \
		C_FLAGS="-Wno-error=discarded-qualifiers"; \
	fi && \
	cmake -S /src/src -B /build \
		-DCMAKE_INSTALL_PREFIX=/usr \
		${C_FLAGS:+-DCMAKE_C_FLAGS=$C_FLAGS} \
		-DUSE_FSAL_CEPH=OFF -DUSE_FSAL_GLUSTER=OFF -DUSE_FSAL_GPFS=OFF \
		-DUSE_FSAL_KVSFS=OFF -DUSE_FSAL_LIZARDFS=OFF -DUSE_FSAL_LUSTRE=OFF \
		-DUSE_FSAL_PROXY_V3=OFF -DUSE_FSAL_PROXY_V4=OFF -DUSE_FSAL_RGW=OFF \
		-DUSE_FSAL_XFS=OFF -DUSE_GSS=OFF -DUSE_MONITORING=OFF && \
	cmake --build /build --parallel "$(nproc)" && \
	DESTDIR=/ganesha-root cmake --install /build

# The Ubuntu packages providing the shared libraries Ganesha links
# against, so the runtime image installs them without any build tools.
# The loop reads a file rather than a pipe, so a library no package
# provides fails the build.
RUN find /ganesha-root -type f \( -name '*.so*' -o -perm -u+x \) -print0 | \
		LD_LIBRARY_PATH=/ganesha-root/usr/lib:/ganesha-root/usr/lib/ganesha xargs -0 ldd 2>/dev/null | \
		awk '$2 == "=>" && $3 ~ /^\// {print $3}' | grep -v '^/ganesha-root/' | sort -u > /linked-libraries && \
	while read -r lib; do \
		dpkg -S "$lib" 2>/dev/null || dpkg -S "$(readlink -f "$lib")" 2>/dev/null || dpkg -S "/usr$lib" 2>/dev/null || \
			{ echo "ERROR: no package provides $lib" >&2; exit 1; }; \
	done < /linked-libraries > /library-packages && \
	cut -d: -f1 /library-packages | sort -u > /runtime-packages && \
	cat /runtime-packages


FROM ${BASE_IMAGE}

ARG LEILFS_VERSION=""
ARG GANESHA_VERSION=""
LABEL io.leil.leilfs.version="${LEILFS_VERSION}"

COPY --from=build /runtime-packages /leilfs-version /ganesha-version /tmp/
COPY --from=build /ganesha-root/ /

# rpcbind for Ganesha's service registration (see leil-ganesha.start.sh).
# The FSAL package installs its library where Ubuntu's Ganesha looks for
# FSALs, not where this Ganesha (prefix /usr) does.
RUN apt-get update && \
	xargs -a /tmp/runtime-packages apt-get install -y --no-install-recommends && \
	apt-get install -y --no-install-recommends rpcbind \
		saunafs-nfs-ganesha="$(cat /tmp/leilfs-version)" \
		saunafs-lib-client="$(cat /tmp/leilfs-version)" && \
	mkdir -p /usr/lib/ganesha && \
	ln -sf /usr/lib/x86_64-linux-gnu/ganesha/libfsalsaunafs.so /usr/lib/ganesha/libfsalsaunafs.so && \
	# Ganesha's sample configuration, which would stop the start script from
	# writing the LeilFS one
	rm -f /etc/ganesha/ganesha.conf && \
	ldconfig && \
	echo "NFS-Ganesha $(cat /tmp/ganesha-version) for the FSAL of LeilFS $(cat /tmp/leilfs-version)" && \
	ganesha.nfsd -v | grep -F "Release = V$(cat /tmp/ganesha-version)" && \
	rm -rf /tmp/runtime-packages /tmp/leilfs-version /tmp/ganesha-version && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*

COPY leil-ganesha.start.sh /leil-ganesha.start.sh
RUN chmod +x /leil-ganesha.start.sh

# NFS, and for NFSv3 also rpcbind and MNT (see leil-ganesha.start.sh)
EXPOSE 2049 111 20048

CMD ["/leil-ganesha.start.sh"]
