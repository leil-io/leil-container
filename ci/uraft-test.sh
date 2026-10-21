#! /bin/bash

# Failover test for the uRaft compose cluster. It starts the cluster from
# already built images, writes a file, stops the uRaft leader and checks
# that another node takes over the floating IP, that the file kept its
# content, and that new files can be written. Then it starts the old
# leader again and checks that it rejoins without taking the floating IP.
# The cluster is left running so its logs can be inspected; stop it with
# 'docker compose -f docker-compose.uraft.yml down'.
#
# Use the same environment variables as for 'docker compose up', e.g.:
#   TAG_SUFFIX=ubuntu-24.04 BASE_IMAGE=leil-base:ubuntu-24.04 ci/uraft-test.sh
#
# It needs a fresh volumes/ directory, so it refuses to run when a
# previous run left data there. Stop the default stack first, as both
# publish the same CGI port.

set -eo pipefail # Exit on command failures, including failed pipeline stages.

cd "$(dirname "${0}")/.."

if [ -d volumes/leil-uraft1 ]; then
	echo "FAIL: volumes/leil-uraft1 exists; remove the data a previous run left in volumes/ first" >&2
	exit 1
fi

CLIENT=leil-uraft-client
MASTER=172.30.0.100 # The floating IP
CHUNKSERVERS=3
TEST_FILE="/mnt/leil/ci/data.bin"
NODES=(leil-uraft1 leil-uraft2 leil-uraft3)

# shellcheck source=ci/lib.sh
source ci/lib.sh

function compose() {
	docker compose -f docker-compose.uraft.yml "${@}"
}

# Prints the nodes holding the floating IP, one per line.
function floating_ip_holders() {
	local node
	for node in "${NODES[@]}"; do
		if [ "$(docker inspect -f '{{.State.Running}}' "${node}")" = true ] &&
			docker exec "${node}" ip -4 -o addr show | grep -qF " ${MASTER}/"; then
			echo "${node}"
		fi
	done
}

# Succeeds when exactly one node, other than the optional argument, holds
# the floating IP.
function single_leader() {
	local holders
	holders="$(floating_ip_holders)"
	[ "$(grep -c . <<< "${holders}")" -eq 1 ] && [ "${holders}" != "${1:-}" ]
}

function metadataservers_connected() {
	[ "$(client leil-admin list-metadataservers "${MASTER}" 9421 | grep -c '^Server ')" -eq "${#NODES[@]}" ]
}

echo "Starting the uRaft cluster..."
compose up -d
wait_for "a single uRaft leader" single_leader
wait_for_cluster
wait_for "${#NODES[@]} metadata servers to connect" metadataservers_connected

write_file "${TEST_FILE}"
checksum="$(file_checksum)"

leader="$(floating_ip_holders)"
echo "Stopping the uRaft leader ${leader}..."
docker stop "${leader}" >/dev/null
wait_for "another node to take over the floating IP" single_leader "${leader}"
echo "OK: $(floating_ip_holders) is the new leader"

wait_for "${TEST_FILE} to be readable after the failover" client test -f "${TEST_FILE}"
[ "$(file_checksum)" = "${checksum}" ] ||
	fail "${TEST_FILE} checksum changed after the failover"
echo "OK: ${TEST_FILE} kept its checksum after the failover"

# A write before the chunkservers reconnect gets fewer copies, and a new
# master delays replication (REPLICATIONS_DELAY_INIT), so wait for them.
wait_for "${CHUNKSERVERS} chunkservers to register with the new leader" chunkservers_registered
write_file "/mnt/leil/ci/after-failover.bin"
file_checksum "/mnt/leil/ci/after-failover.bin" >/dev/null
echo "OK: files can be written after the failover"

echo "Starting the old leader ${leader} again..."
docker start "${leader}" >/dev/null
wait_for "${#NODES[@]} metadata servers to connect" metadataservers_connected
single_leader "${leader}" || fail "the floating IP is not held by exactly one node other than ${leader}"
echo "OK: ${leader} rejoined without taking the floating IP"

echo "uRaft test passed."
