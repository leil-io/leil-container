#! /bin/bash

set -e # Exit on error

function start_client() {
	MOUNTPOINT=${1}
	mkdir -p "${MOUNTPOINT}"
	# The leil-mount command will be run with all provided arguments.
	# The -f flag keeps it in the foreground, which is typical for containerized services.
	# exec makes it PID 1, so it receives SIGTERM on container stop and unmounts cleanly.
	exec leil-mount -f "${@}"
}

# Call start_client with all script arguments
start_client "${@}"
