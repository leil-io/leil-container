ARG BASE_IMAGE=leil-base:ubuntu-24.04

# Builds NFS-Ganesha from source the way the LeilFS release it serves does,
# as the LeilFS FSAL only loads into the Ganesha release it is built against
# and Ubuntu does not ship most of them.
FROM ${BASE_IMAGE} AS build

# Allow version pinning: --build-arg LEILFS_VERSION=5.12.0-1
ARG LEILFS_VERSION=""
# Where the LeilFS sources are, for raw files at a tag or commit
ARG LEILFS_SOURCES=https://raw.githubusercontent.com/leil-io/leilfs

# The LeilFS version is resolved here, once, so the FSAL installed below is
# the one Ganesha is built for even if the repository changes meanwhile.
#
# LeilFS keeps how it builds Ganesha in tests/ci_build/ganesha: the release
# (ganesha.env), the build dependencies (ganesha-deps.txt) and the build
# with its CMake options (build-ganesha.sh). The FSAL is built against that
# release, so they are taken from the same LeilFS release as the FSAL: its
# tag, e.g. v5.12.0 for 5.12.0-1, or the commit an experimental version
# names. LeilFS releases before 5.12 do not have them.
RUN apt-get update && \
	apt-get install -y --no-install-recommends ca-certificates curl && \
	if [ -z "$LEILFS_VERSION" ]; then \
		LEILFS_VERSION="$(apt-cache madison saunafs-nfs-ganesha | awk 'NR == 1 {print $3}')"; \
	fi && \
	apt-cache madison saunafs-nfs-ganesha | awk '{print $3}' | grep -qxF -- "$LEILFS_VERSION" || \
		{ echo "ERROR: saunafs-nfs-ganesha $LEILFS_VERSION is not in the repository." >&2; exit 1; } && \
	echo "$LEILFS_VERSION" > /leilfs-version && \
	UPSTREAM="${LEILFS_VERSION%-*}" && \
	COMMIT="$(echo "$UPSTREAM" | grep -oE '[0-9a-f]{40}' | tail -1 || true)" && \
	REF="${COMMIT:-v$(echo "$UPSTREAM" | tr '~' '-')}" && \
	mkdir -p /opt/ganesha && \
	for file in ganesha.env ganesha-deps.txt build-ganesha.sh; do \
		curl -fsSL -o "/opt/ganesha/$file" "$LEILFS_SOURCES/$REF/tests/ci_build/ganesha/$file" || \
			{ echo "ERROR: cannot get tests/ci_build/ganesha/$file of LeilFS $LEILFS_VERSION at $REF; this image needs LeilFS 5.12 or later." >&2; exit 1; }; \
	done && \
	. /opt/ganesha/ganesha.env && \
	echo "LeilFS $LEILFS_VERSION ($REF) builds its FSAL against NFS-Ganesha $GANESHA_VERSION" && \
	grep -vE '^[[:space:]]*(#|$)' /opt/ganesha/ganesha-deps.txt | \
		DEBIAN_FRONTEND=noninteractive xargs apt-get install -y --no-install-recommends && \
	rm -rf /var/lib/apt/lists/*

# build-ganesha.sh installs into /usr, so DESTDIR collects what it installs
# for the runtime image. Ganesha before V15.4 does not build on Ubuntu 26.04
# with -Werror (fixed upstream in bsd-base64.c).
RUN . /opt/ganesha/ganesha.env && \
	. /etc/os-release && \
	if [ "$VERSION_ID" = 26.04 ] && dpkg --compare-versions "${GANESHA_VERSION#V}" lt 15.4; then \
		export CFLAGS="-Wno-error=discarded-qualifiers"; \
	fi && \
	DESTDIR=/ganesha-root bash /opt/ganesha/build-ganesha.sh /usr

# The Ubuntu packages providing the shared libraries Ganesha links
# against, so the runtime image installs them without any build tools or
# the test tools ganesha-deps.txt also lists. A library ldd cannot find
# ("not found") or no package provides fails the build: Ganesha loads its
# FSALs only at runtime, so nothing later in the build would notice one
# missing. The loop reads a file rather than a pipe, so its exit fails the
# build. Ganesha's own libntirpc goes to the multiarch directory, e.g.
# usr/lib/x86_64-linux-gnu.
RUN MULTIARCH="$(gcc -print-multiarch)" && \
	find /ganesha-root -type f \( -name '*.so*' -o -perm -u+x \) -print0 | \
		LD_LIBRARY_PATH="/ganesha-root/usr/lib:/ganesha-root/usr/lib/$MULTIARCH:/ganesha-root/usr/lib/ganesha" \
		xargs -0 ldd 2>/dev/null > /ldd-output || true && \
	if grep -F 'not found' /ldd-output; then \
		echo "ERROR: Ganesha links against the libraries above, which ldd cannot find" >&2; exit 1; \
	fi && \
	awk '$2 == "=>" && $3 ~ /^\// {print $3}' /ldd-output | grep -v '^/ganesha-root/' | sort -u > /linked-libraries && \
	while read -r lib; do \
		dpkg -S "$lib" 2>/dev/null || dpkg -S "$(readlink -f "$lib")" 2>/dev/null || dpkg -S "/usr$lib" 2>/dev/null || \
			{ echo "ERROR: no package provides $lib" >&2; exit 1; }; \
	done < /linked-libraries > /library-packages && \
	cut -d: -f1 /library-packages | sort -u > /runtime-packages && \
	cat /runtime-packages


FROM ${BASE_IMAGE}

ARG LEILFS_VERSION=""
LABEL io.leil.leilfs.version="${LEILFS_VERSION}"

COPY --from=build /runtime-packages /leilfs-version /opt/ganesha/ganesha.env /tmp/
COPY --from=build /ganesha-root/ /

# rpcbind for Ganesha's service registration (see leil-nfs-ganesha.start.sh),
# and ibverbs-providers for RDMA, which build-ganesha.sh enables: Ganesha
# loads the providers at runtime, so ldd does not find them.
# The FSAL package installs its library where Ubuntu's Ganesha looks for
# FSALs, not where this Ganesha (prefix /usr) does, so it is linked there,
# from the path the package lists. Ganesha only loads it when an export
# starts, so the build checks here that it exists and that ldd finds all
# the libraries it needs.
RUN apt-get update && \
	xargs -a /tmp/runtime-packages apt-get install -y --no-install-recommends && \
	apt-get install -y --no-install-recommends rpcbind ibverbs-providers \
		saunafs-nfs-ganesha="$(cat /tmp/leilfs-version)" \
		saunafs-lib-client="$(cat /tmp/leilfs-version)" && \
	FSAL="$(dpkg -L saunafs-nfs-ganesha | grep '/libfsalsaunafs\.so$' | head -1)" && \
	{ [ -f "$FSAL" ] || { echo "ERROR: saunafs-nfs-ganesha installs no libfsalsaunafs.so" >&2; exit 1; }; } && \
	mkdir -p /usr/lib/ganesha && \
	{ [ "$FSAL" = /usr/lib/ganesha/libfsalsaunafs.so ] || ln -sf "$FSAL" /usr/lib/ganesha/libfsalsaunafs.so; } && \
	# Ganesha's sample configuration, which would stop the start script from
	# writing the LeilFS one
	rm -f /etc/ganesha/ganesha.conf && \
	ldconfig && \
	if ldd /usr/lib/ganesha/libfsalsaunafs.so | grep -F 'not found'; then \
		echo "ERROR: the FSAL needs the libraries above, which ldd cannot find" >&2; exit 1; \
	fi && \
	. /tmp/ganesha.env && \
	echo "NFS-Ganesha $GANESHA_VERSION for the FSAL of LeilFS $(cat /tmp/leilfs-version)" && \
	ganesha.nfsd -v | grep -F "Release = $GANESHA_VERSION" && \
	rm -f /tmp/runtime-packages /tmp/leilfs-version /tmp/ganesha.env && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*

COPY leil-nfs-ganesha.start.sh /leil-nfs-ganesha.start.sh
RUN chmod +x /leil-nfs-ganesha.start.sh

# NFS, and for NFSv3 also rpcbind and MNT (see leil-nfs-ganesha.start.sh)
EXPOSE 2049 111 20048

CMD ["/leil-nfs-ganesha.start.sh"]
