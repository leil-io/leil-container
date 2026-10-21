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

# shellcheck source=ci/lib.sh
source ci/lib.sh

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

write_file "${TEST_FILE}"
checksum="$(file_checksum)"
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
