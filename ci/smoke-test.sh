#! /bin/bash

# Smoke test for the docker compose cluster. It starts the cluster from
# already built images, writes a file, restarts the cluster and checks
# that the file survived, and checks that monitoring and the metalogger
# work. The cluster is left running so its logs can be inspected; stop it
# with 'docker compose down'.
#
# Use the same environment variables as for 'docker compose up', e.g.:
#   TAG_SUFFIX=ubuntu-24.04 BASE_IMAGE=leil-base:ubuntu-24.04 ci/smoke-test.sh
#
# It needs a fresh volumes/ directory, so it refuses to run when a
# previous run left data there.

set -eo pipefail # Exit on command failures, including failed pipeline stages.

# Keep stderr on fd 3, so fail() is visible inside wait_for, which
# silences the commands it retries.
exec 3>&2

cd "$(dirname "${0}")/.."

if [ -d volumes/leil-master ]; then
	echo "FAIL: volumes/leil-master exists; remove the data a previous run left in volumes/ first" >&2
	exit 1
fi

CHUNKSERVERS=3
TEST_DIR="/mnt/leil/ci"
TEST_FILE="${TEST_DIR}/data.bin"
CGI_URL="http://localhost:29425/leil.cgi?masterhost=master&sections=CS"
TIMEOUT=120

function fail() {
	echo "FAIL: ${*}" >&3
	exit 1
}

# wait_for <description> <command...>: retry the command until it succeeds.
function wait_for() {
	local description="${1}"
	shift
	echo "Waiting for ${description}..."
	for ((i = 0; i < TIMEOUT; i++)); do
		if "${@}" >/dev/null 2>&1; then
			echo "OK: ${description}"
			return 0
		fi
		sleep 1
	done
	fail "timed out after ${TIMEOUT}s waiting for ${description}"
}

function client() {
	docker exec leil-client "${@}"
}

# Fails at once when the client container has exited, as it does when
# the mount fails, instead of waiting for the timeout.
function require_client_running() {
	[ "$(docker inspect -f '{{.State.Running}}' leil-client)" = true ] ||
		fail "the client container exited; see 'docker compose logs client'"
}

function chunkservers_registered() {
	require_client_running
	[ "$(client leil-admin list-chunkservers --porcelain master 9421 | wc -l)" -eq "${CHUNKSERVERS}" ]
}

# Not piped into 'grep -q', which would fail the pipeline with SIGPIPE
# under pipefail when grep exits before reading all the output.
function file_has_two_copies() {
	grep -q "chunks with 2 copies" <<< "$(client leil checkfile "${TEST_FILE}")"
}

function file_checksum() {
	local checksum
	checksum="$(client sha256sum "${TEST_FILE}" | cut -d' ' -f1)"
	[ -n "${checksum}" ] || fail "cannot read the checksum of ${TEST_FILE}"
	echo "${checksum}"
}

function client_mounted() {
	require_client_running
	client mountpoint -q /mnt/leil
}

function wait_for_cluster() {
	wait_for "${CHUNKSERVERS} chunkservers to register" chunkservers_registered
	wait_for "the client to mount /mnt/leil" client_mounted
}

function check_monitoring() {
	local page
	page="$(curl -fsS "${CGI_URL}")" || fail "CGI server is not reachable at ${CGI_URL}"
	[ "$(grep -oE 'leil-chunkserver0[0-9]' <<< "${page}" | sort -u | wc -l)" -eq "${CHUNKSERVERS}" ] ||
		fail "CGI server does not list ${CHUNKSERVERS} chunkservers"
	echo "OK: CGI server lists ${CHUNKSERVERS} chunkservers"
}

function check_metalogger() {
	wait_for "the metalogger to receive changelogs" \
		docker exec leil-metalogger test -s /var/lib/saunafs/changelog_ml.sfs
}

echo "Starting the cluster..."
docker compose up -d
wait_for_cluster

echo "Writing ${TEST_FILE} with goal 2..."
client mkdir -p "${TEST_DIR}"
client leil setgoal 2 "${TEST_DIR}"
client sh -c "head -c 8M /dev/urandom > '${TEST_FILE}' && sync"
checksum="$(file_checksum)"
wait_for "${TEST_FILE} to have 2 copies" file_has_two_copies
client leil fileinfo "${TEST_FILE}"

check_monitoring
check_metalogger

echo "Restarting the cluster..."
docker compose down
docker compose up -d
wait_for_cluster

wait_for "${TEST_FILE} to be readable after the restart" client test -f "${TEST_FILE}"
[ "$(file_checksum)" = "${checksum}" ] ||
	fail "${TEST_FILE} checksum changed after the restart"
echo "OK: ${TEST_FILE} kept its checksum after the restart"
wait_for "${TEST_FILE} to have 2 copies after the restart" file_has_two_copies

check_monitoring

echo "Smoke test passed."
