#! /bin/bash

# Prints the NFS-Ganesha release the FSAL of the given LeilFS package
# version is built against, e.g. '15.9' for 5.13.0-1.
#
# The FSAL only loads into that release: Ganesha changes the FSAL ABI
# between point releases without bumping FSAL_MAJOR_VERSION, so its own
# version check misses most mismatches. Keep in sync with
# https://docs.leil.io/nfs-client#installing-nfs-ganesha and with the
# leil.storage.deploy role of the deployment repository.

set -euo pipefail

LEILFS_VERSION="${1:?usage: ${0} <LeilFS package version>}"

# First LeilFS release whose FSAL is built against each Ganesha release,
# newest first. ~ sorts before anything, so 5.13.0~rc1 counts as 5.13.0.
while read -r leilfs ganesha; do
	if dpkg --compare-versions "${LEILFS_VERSION}" ge "${leilfs}~"; then
		echo "${ganesha}"
		exit 0
	fi
done <<'EOF'
5.13.0 15.9
5.12.0 9.15
5.5.0 9.2
5.3.0 7.1
4.0.0 4.3
EOF

echo "ERROR: no NFS-Ganesha release is known for the FSAL of LeilFS ${LEILFS_VERSION}." >&2
exit 1
