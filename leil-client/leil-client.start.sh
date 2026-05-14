#! /bin/bash

set -e # Exit on error

function start_client() {
	MOUNTPOINT=${1}
	mkdir -p "${MOUNTPOINT}"
	# The sfsmount command will be run with all provided arguments.
	# The -f flag keeps it in the foreground, which is typical for containerized services.
	sfsmount -f "${@}"
}

# Call start_client with all script arguments
start_client "${@}"
