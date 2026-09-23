#! /bin/bash

# Smoke test for the docker compose cluster. It starts the cluster from
# already built images, writes a file, restarts the cluster and checks
# that the file survived, and checks that monitoring and the metalogger
# work, and that the client unmounts cleanly when its container stops.
# The cluster is left running so its logs can be inspected; stop it
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
		docker exec leil-metalogger test -s /var/lib/leil/changelog_ml.sfs
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

write_file "${TEST_FILE}"
checksum="$(file_checksum)"
client leil fileinfo "${TEST_FILE}"

check_monitoring
check_metalogger
check_client_stops_cleanly

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
