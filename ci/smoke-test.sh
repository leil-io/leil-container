#! /bin/bash

# Smoke test for the docker compose cluster. It starts the cluster from
# already built images, writes a file, restarts the cluster and checks
# that the file survived, and checks that monitoring, the metalogger and
# the NFS export of NFS-Ganesha work, and that the client unmounts cleanly
# when its container stops. The cluster is left running so its logs can be
# inspected; stop it
# with 'docker compose down'.
#
# Use the same environment variables as for 'docker compose up', e.g.:
#   TAG_SUFFIX=ubuntu-24.04 BASE_IMAGE=leil-base:ubuntu-24.04 ci/smoke-test.sh
#
# It needs a fresh volumes/ directory, so it refuses to run when a
# previous run left data there.

set -eo pipefail # Exit on command failures, including failed pipeline stages.

cd "$(dirname "${0}")/.."

if [ -d volumes/leil-master ]; then
	echo "FAIL: volumes/leil-master exists; remove the data a previous run left in volumes/ first" >&2
	exit 1
fi

CLIENT=leil-client
MASTER=master
CHUNKSERVERS=3
TEST_FILE="/mnt/leil/ci/data.bin"
CGI_URL="http://localhost:29425/leil.cgi?masterhost=master&sections=CS"
NFS_TEST_FILE="/mnt/leil/ci/nfs.bin"
# The NFS URL of a path in LeilFS, i.e. under /mnt/leil in the client
NFS_URL="nfs://leil-nfs-ganesha"
NFS_CLIENT=leil-nfs-test
# A second gateway without NFS_CLIENTS, which exports LeilFS read-only
READ_ONLY_GATEWAY=leil-nfs-ganesha-read-only
# Whatever Ubuntu the gateway runs on: the libnfs of Ubuntu 22.04 (4.0.0)
# fails to write over NFSv4.
NFS_CLIENT_IMAGE=ubuntu:24.04

# shellcheck source=ci/lib.sh
source ci/lib.sh

function check_monitoring() {
	local page
	page="$(curl -fsS "${CGI_URL}")" || fail "CGI server is not reachable at ${CGI_URL}"
	[ "$(grep -oE 'leil-chunkserver0[0-9]' <<< "${page}" | sort -u | wc -l)" -eq "${CHUNKSERVERS}" ] ||
		fail "CGI server does not list ${CHUNKSERVERS} chunkservers"
	echo "OK: CGI server lists ${CHUNKSERVERS} chunkservers"
}

# A userspace NFS client (libnfs), so the test needs no NFS support in the
# kernel of the machine it runs on
function start_nfs_client() {
	local network
	network="$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' leil-nfs-ganesha)"
	docker rm -f "${NFS_CLIENT}" >/dev/null 2>&1 || true
	docker run -d --name "${NFS_CLIENT}" --network "${network}" --entrypoint sleep \
		"${NFS_CLIENT_IMAGE}" infinity >/dev/null
	docker exec "${NFS_CLIENT}" sh -c \
		'apt-get update -qq && apt-get install -y -qq --no-install-recommends libnfs-utils >/dev/null' ||
		fail "cannot install libnfs-utils in the NFS test client"
}

function nfs_client() {
	docker exec "${NFS_CLIENT}" "${@}"
}

# nfs_exports_leilfs [gateway]: whether the gateway lists TEST_FILE in
# its directory. Ganesha answers with an empty pseudo-root when it could
# not create the LeilFS export, so listing the root would not tell.
# Not piped into 'grep -q', see file_has_two_copies in ci/lib.sh.
function nfs_exports_leilfs() {
	local dir="${TEST_FILE%/*}"
	grep -qF "${TEST_FILE##*/}" <<< \
		"$(nfs_client nfs-ls "nfs://${1:-leil-nfs-ganesha}${dir#/mnt/leil}?version=4")"
}

# nfs_read_checksum <path in LeilFS> [gateway]: the checksum of the file
# read through NFS, failing when the read fails, as sha256sum would
# otherwise print the checksum of no data.
function nfs_read_checksum() {
	nfs_client bash -o pipefail -c \
		"nfs-cat 'nfs://${2:-leil-nfs-ganesha}${1#/mnt/leil}?version=4' | sha256sum | cut -d' ' -f1"
}

# nfs_checksum <path in LeilFS>: like nfs_read_checksum, failing the test
# when the file cannot be read.
function nfs_checksum() {
	nfs_read_checksum "${1}" || fail "cannot read ${1} through NFS"
}

# nfs_reads_same <path in LeilFS>: whether the file reads through NFS with
# the checksum it has in the LeilFS client; without fail(), for wait_for.
function nfs_reads_same() {
	local checksum
	checksum="$(nfs_read_checksum "${1}")" && [ "${checksum}" = "$(file_checksum "${1}")" ]
}

# Reads through NFS what the LeilFS client wrote, and writes through NFS a
# file the LeilFS client then reads, so the export serves LeilFS itself.
function check_nfs() {
	wait_for "NFS-Ganesha to export LeilFS" nfs_exports_leilfs

	[ "$(nfs_checksum "${TEST_FILE}")" = "${checksum}" ] ||
		fail "${TEST_FILE} reads differently through NFS"
	echo "OK: ${TEST_FILE} reads the same through NFS"

	nfs_client sh -c "head -c 8M /dev/urandom > /tmp/nfs.bin"
	nfs_client nfs-cp /tmp/nfs.bin "${NFS_URL}${NFS_TEST_FILE#/mnt/leil}?version=4" ||
		fail "cannot write ${NFS_TEST_FILE} through NFS"
	[ "$(file_checksum "${NFS_TEST_FILE}")" = "$(nfs_client sha256sum /tmp/nfs.bin | cut -d' ' -f1)" ] ||
		fail "${NFS_TEST_FILE}, written through NFS, reads differently through the LeilFS client"
	echo "OK: a file written through NFS reads the same through the LeilFS client"
}

function remove_read_only_gateway() {
	docker rm -f "${READ_ONLY_GATEWAY}" >/dev/null 2>&1 || true
}

# Without NFS_CLIENTS, a gateway exports LeilFS read-only to any host.
function check_nfs_read_only_default() {
	local image network output
	image="$(docker inspect -f '{{.Config.Image}}' leil-nfs-ganesha)"
	network="$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' leil-nfs-ganesha)"
	on_exit remove_read_only_gateway
	remove_read_only_gateway
	docker run -d --name "${READ_ONLY_GATEWAY}" --network "${network}" -e MASTER_HOST="${MASTER}" \
		"${image}" >/dev/null
	wait_for "a gateway without NFS_CLIENTS to export LeilFS" nfs_exports_leilfs "${READ_ONLY_GATEWAY}"

	[ "$(nfs_read_checksum "${TEST_FILE}" "${READ_ONLY_GATEWAY}")" = "${checksum}" ] ||
		fail "${TEST_FILE} does not read the same through a gateway without NFS_CLIENTS"
	if output="$(nfs_client nfs-cp /tmp/nfs.bin \
		"nfs://${READ_ONLY_GATEWAY}${NFS_TEST_FILE#/mnt/leil}.read-only?version=4" 2>&1)"; then
		fail "a gateway without NFS_CLIENTS let the NFS client write"
	fi
	grep -qF NFS4ERR_ROFS <<< "${output}" ||
		fail "writing through a gateway without NFS_CLIENTS failed, but not as read-only: ${output}"
	echo "OK: a gateway without NFS_CLIENTS serves LeilFS read-only"
	remove_read_only_gateway
}

function check_metalogger() {
	wait_for "the metalogger to receive changelogs" \
		docker exec leil-metalogger test -s /var/lib/saunafs/changelog_ml.sfs
}

# A second client whose mount is shared with the host. Compose does not
# manage it, so 'docker compose down' would leave it behind.
HOST_CLIENT=leil-client-hostmount
HOST_CLIENT_DIR=""
CLIENT_IMAGE=""

# Removes the second client and its mount directory. Registered with
# on_exit, so it also runs when a check failed or timed out. A dead mount
# it left behind is removed through the shared bind mount, as the host may
# not allow unmounting it directly.
function remove_host_client() {
	docker rm -f "${HOST_CLIENT}" >/dev/null 2>&1 || true
	[ -n "${HOST_CLIENT_DIR}" ] || return 0
	if findmnt "${HOST_CLIENT_DIR}/mnt" >/dev/null 2>&1; then
		docker run --rm --privileged -v "${HOST_CLIENT_DIR}:${HOST_CLIENT_DIR}:rshared" \
			--entrypoint umount "${CLIENT_IMAGE}" -l "${HOST_CLIENT_DIR}/mnt" >/dev/null 2>&1 || true
	fi
	rm -rf "${HOST_CLIENT_DIR}" 2>/dev/null || true
	HOST_CLIENT_DIR=""
}

# A client that does not get SIGTERM is killed when its container stops,
# and leaves a dead mount behind ("Transport endpoint is not connected").
# It only gets SIGTERM when leil-mount is PID 1, so check that the client
# stops on SIGTERM, and that it unmounts a mount shared with the host.
function check_client_stops_cleanly() {
	local network code
	CLIENT_IMAGE="$(docker inspect -f '{{.Config.Image}}' "${CLIENT}")"
	network="$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' "${CLIENT}")"

	echo "Stopping ${CLIENT}..."
	docker stop -t 30 "${CLIENT}" >/dev/null
	code="$(docker inspect -f '{{.State.ExitCode}}' "${CLIENT}")"
	[ "${code}" != 137 ] ||
		fail "${CLIENT} ignored SIGTERM and was killed; leil-mount must run as PID 1"
	echo "OK: ${CLIENT} stopped on SIGTERM (exit code ${code})"
	docker start "${CLIENT}" >/dev/null
	wait_for "the client to mount /mnt/leil again" client_mounted

	# A second client whose mount is shared with the host, as when the
	# container replaces a client installed on the host. Its mount only
	# reaches the host when the mount holding the temp directory is shared
	# and Docker runs on this host, not in a VM like Docker Desktop.
	local tmp propagation
	tmp="${TMPDIR:-/tmp}"
	propagation="$(findmnt -no PROPAGATION -T "${tmp}" 2>/dev/null || true)"
	if [[ "${propagation}" != *shared* ]]; then
		echo "SKIP: ${tmp} is on a mount with '${propagation:-unknown}' propagation, not shared, so a client mount cannot reach the host"
		return 0
	fi
	if [[ "$(docker info -f '{{.OperatingSystem}}' 2>/dev/null)" == *"Docker Desktop"* ]]; then
		echo "SKIP: Docker Desktop runs containers in a VM, so a client mount cannot reach this host"
		return 0
	fi

	# Remove it on every exit, including failed checks and timeouts, and
	# remove one a previous run left behind before starting it.
	on_exit remove_host_client
	docker rm -f "${HOST_CLIENT}" >/dev/null 2>&1 || true
	HOST_CLIENT_DIR="$(mktemp -d)"
	docker run -d --name "${HOST_CLIENT}" --network "${network}" \
		--device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor:unconfined \
		-v "${HOST_CLIENT_DIR}:${HOST_CLIENT_DIR}:rshared" "${CLIENT_IMAGE}" \
		"${HOST_CLIENT_DIR}/mnt" -H "${MASTER}" -P 9421 -S / >/dev/null
	wait_for "the host to see the mount of ${HOST_CLIENT}" findmnt "${HOST_CLIENT_DIR}/mnt"
	docker stop -t 30 "${HOST_CLIENT}" >/dev/null
	! findmnt "${HOST_CLIENT_DIR}/mnt" >/dev/null ||
		fail "${HOST_CLIENT} left its mount on the host after it stopped"
	echo "OK: ${HOST_CLIENT} removed its mount from the host when it stopped"
	remove_host_client
}

echo "Starting the cluster..."
docker compose up -d
wait_for_cluster
# Registered first, as start_nfs_client fails the test when it cannot
# install libnfs, leaving the client attached to the network
on_exit 'docker rm -f "${NFS_CLIENT}" >/dev/null 2>&1 || true'
start_nfs_client

write_file "${TEST_FILE}"
checksum="$(file_checksum)"
client leil fileinfo "${TEST_FILE}"

check_monitoring
check_metalogger
check_nfs
check_nfs_read_only_default
check_client_stops_cleanly

echo "Restarting the cluster..."
# Attached to the cluster's network, it would stop 'down' from removing it
docker rm -f "${NFS_CLIENT}" >/dev/null
docker compose down
docker compose up -d
wait_for_cluster
start_nfs_client

wait_for "${TEST_FILE} to be readable after the restart" client test -f "${TEST_FILE}"
[ "$(file_checksum)" = "${checksum}" ] ||
	fail "${TEST_FILE} checksum changed after the restart"
echo "OK: ${TEST_FILE} kept its checksum after the restart"
wait_for "${TEST_FILE} to have 2 copies after the restart" file_has_two_copies

check_monitoring

wait_for "NFS-Ganesha to export LeilFS after the restart" nfs_exports_leilfs
# Ganesha restarts with the test client in its recovery state, so it
# refuses to open files (NFS4ERR_GRACE) until its grace period ends.
wait_for "${TEST_FILE} to read the same through NFS after the grace period" nfs_reads_same "${TEST_FILE}"

echo "Smoke test passed."
