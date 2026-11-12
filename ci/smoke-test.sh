#! /bin/bash

# Smoke test for the docker compose cluster. It starts the cluster from
# already built images, writes a file, restarts the cluster and checks
# that the file survived, and checks that monitoring, the metalogger and
# the NFS export of NFS-Ganesha work. The cluster is left running so its logs can be inspected; stop it
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
NFS_URL="nfs://leil-ganesha"
NFS_CLIENT=leil-nfs-test
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
	network="$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' leil-ganesha)"
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

function nfs_export_listed() {
	nfs_client nfs-ls "${NFS_URL}/?version=4"
}

# nfs_checksum <path in LeilFS>: the checksum of the file read through NFS
function nfs_checksum() {
	local checksum
	checksum="$(nfs_client sh -c "nfs-cat '${NFS_URL}${1#/mnt/leil}?version=4' | sha256sum" | cut -d' ' -f1)"
	[ -n "${checksum}" ] || fail "cannot read ${1} through NFS"
	echo "${checksum}"
}

# nfs_reads_same <path in LeilFS>: whether the file reads through NFS with
# the checksum it has in the LeilFS client; without fail(), for wait_for.
function nfs_reads_same() {
	[ "$(nfs_client sh -c "nfs-cat '${NFS_URL}${1#/mnt/leil}?version=4' | sha256sum" | cut -d' ' -f1)" = \
		"$(file_checksum "${1}")" ]
}

# Reads through NFS what the LeilFS client wrote, and writes through NFS a
# file the LeilFS client then reads, so the export serves LeilFS itself.
function check_nfs() {
	wait_for "NFS-Ganesha to export LeilFS" nfs_export_listed

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

function check_metalogger() {
	wait_for "the metalogger to receive changelogs" \
		docker exec leil-metalogger test -s /var/lib/saunafs/changelog_ml.sfs
}

echo "Starting the cluster..."
docker compose up -d
wait_for_cluster
start_nfs_client
trap 'docker rm -f "${NFS_CLIENT}" >/dev/null 2>&1 || true' EXIT

write_file "${TEST_FILE}"
checksum="$(file_checksum)"
client leil fileinfo "${TEST_FILE}"

check_monitoring
check_metalogger
check_nfs

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

wait_for "NFS-Ganesha to export LeilFS after the restart" nfs_export_listed
# Ganesha restarts with the test client in its recovery state, so it
# refuses to open files (NFS4ERR_GRACE) until its grace period ends.
wait_for "${TEST_FILE} to read the same through NFS after the grace period" nfs_reads_same "${TEST_FILE}"

echo "Smoke test passed."
