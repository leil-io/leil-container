#! /bin/bash

set -e # Exit immediately if a command exits with a non-zero status.

TARGET_CONF_DIR="/etc/saunafs"
DEFAULT_CONF_SRC_DIR="/usr/share/doc/saunafs-master/examples"
TARGET_DATA_DIR="/var/lib/saunafs"
# Path in the image where the Dockerfile copied the pristine metadata.sfs.empty
IMAGE_METADATA_TEMPLATE_PATH="/opt/saunafs/templates/metadata.sfs.empty"
SAUNAFS_USER="saunafs"

echo "Ensuring LeilFS Master directories and configurations..."

mkdir -p "${TARGET_CONF_DIR}"

# Check if main config file exists, if not, copy all defaults
if [ ! -f "${TARGET_CONF_DIR}/sfsmaster.cfg" ]; then
	echo "'${TARGET_CONF_DIR}/sfsmaster.cfg' not found. Copying default configurations from '${DEFAULT_CONF_SRC_DIR}'..."
	if [ -d "${DEFAULT_CONF_SRC_DIR}" ] && [ "$(ls -A "${DEFAULT_CONF_SRC_DIR}")" ]; then
		cp -av "${DEFAULT_CONF_SRC_DIR}/." "${TARGET_CONF_DIR}/"
		echo "Default configurations copied."
	else
		echo "ERROR: Default configuration source directory '${DEFAULT_CONF_SRC_DIR}' is empty or does not exist. Check package installation and unminimize."
		exit 1
	fi
else
	echo "Existing '${TARGET_CONF_DIR}/sfsmaster.cfg' found."
fi

mkdir -p "${TARGET_DATA_DIR}"

# Initialize metadata.sfs from the image's template if the data directory (volume) is empty.
if [ ! "$(ls -A "${TARGET_DATA_DIR}")" ]; then
	echo "Target data directory '${TARGET_DATA_DIR}' is empty. Initializing 'metadata.sfs' from image template '${IMAGE_METADATA_TEMPLATE_PATH}'..."
	cp -v "${IMAGE_METADATA_TEMPLATE_PATH}" "${TARGET_DATA_DIR}/metadata.sfs"
	echo "'metadata.sfs' initialized."
else
	echo "Target data directory '${TARGET_DATA_DIR}' is not empty. Skipping 'metadata.sfs' initialization."
fi

# Handle potential lock file from a previous unclean shutdown
if [ -f "${TARGET_DATA_DIR}/metadata.sfs.lock" ]; then
	echo "Stale '${TARGET_DATA_DIR}/metadata.sfs.lock' found."
	echo "Removing '${TARGET_DATA_DIR}/metadata.sfs.lock'..."
	rm -f "${TARGET_DATA_DIR}/metadata.sfs.lock"
	echo "Attempting recovery using 'sfsmetarestore -a'..."
	sfsmetarestore -a # This command should handle its own errors or messages.
	echo "Recovery attempt finished."
fi

echo "Setting final ownership for '${TARGET_CONF_DIR}' and '${TARGET_DATA_DIR}' to '${SAUNAFS_USER}'..."
chown -R "${SAUNAFS_USER}:${SAUNAFS_USER}" "${TARGET_CONF_DIR}"
chown -R "${SAUNAFS_USER}:${SAUNAFS_USER}" "${TARGET_DATA_DIR}"

echo "Starting LeilFS Master..."
# Using exec to replace the shell process with sfsmaster
exec sfsmaster -d -u
