#! /bin/bash

# Helpers shared by the cluster tests. Before sourcing it, set:
#   CLIENT        name of the client container
#   MASTER        address the client tools use to reach the master
#   CHUNKSERVERS  number of chunkservers the cluster runs
#   TEST_FILE     file the test writes through the client mount

TIMEOUT=120

# Keep stderr on fd 3, so fail() is visible inside wait_for, which
# silences the commands it retries.
exec 3>&2

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
	docker exec "${CLIENT}" "${@}"
}

# Fails at once when the client container has exited, as it does when
# the mount fails, instead of waiting for the timeout.
function require_client_running() {
	[ "$(docker inspect -f '{{.State.Running}}' "${CLIENT}")" = true ] ||
		fail "the client container exited; see 'docker logs ${CLIENT}'"
}

function chunkservers_registered() {
	require_client_running
	[ "$(client leil-admin list-chunkservers --porcelain "${MASTER}" 9421 | wc -l)" -eq "${CHUNKSERVERS}" ]
}

function client_mounted() {
	require_client_running
	client mountpoint -q /mnt/leil
}

function wait_for_cluster() {
	wait_for "${CHUNKSERVERS} chunkservers to register" chunkservers_registered
	wait_for "the client to mount /mnt/leil" client_mounted
}

# Not piped into 'grep -q', which would fail the pipeline with SIGPIPE
# under pipefail when grep exits before reading all the output.
function file_has_two_copies() {
	grep -q "chunks with 2 copies" <<< "$(client leil checkfile "${1:-${TEST_FILE}}")"
}

# file_checksum [file]: prints the checksum of the file, by default TEST_FILE.
function file_checksum() {
	local file="${1:-${TEST_FILE}}"
	local checksum
	checksum="$(client sha256sum "${file}" | cut -d' ' -f1)"
	[ -n "${checksum}" ] || fail "cannot read the checksum of ${file}"
	echo "${checksum}"
}

# write_file <file>: writes 8 MiB of random data with goal 2 and waits for
# both copies.
function write_file() {
	local file="${1}"
	echo "Writing ${file} with goal 2..."
	client mkdir -p "$(dirname "${file}")"
	client leil setgoal 2 "$(dirname "${file}")"
	client sh -c "head -c 8M /dev/urandom > '${file}' && sync"
	wait_for "${file} to have 2 copies" file_has_two_copies "${file}"
}
