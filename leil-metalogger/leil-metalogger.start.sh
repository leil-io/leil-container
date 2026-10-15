#! /bin/bash

set -e # Exit on error

TARGET_CONF_DIR="/etc/saunafs"
DEFAULT_CONF_SRC_DIR="/usr/share/doc/saunafs-metalogger/examples"
TARGET_DATA_DIR="/var/lib/saunafs"
SAUNAFS_USER="saunafs"
# Master address, e.g. the uRaft floating IP of an HA cluster. When set,
# it replaces the address in the configuration on every start.
MASTER_HOST="${MASTER_HOST:-}"

echo "Ensuring LeilFS Metalogger directories and configurations..."

mkdir -p "${TARGET_CONF_DIR}"

# Check if main config file exists, if not, copy the default
if [ ! -f "${TARGET_CONF_DIR}/leil-metalogger.cfg" ]; then
	echo "'${TARGET_CONF_DIR}/leil-metalogger.cfg' not found. Copying default configuration from '${DEFAULT_CONF_SRC_DIR}'..."
	if [ -f "${DEFAULT_CONF_SRC_DIR}/leil-metalogger.cfg" ]; then
		cp -v "${DEFAULT_CONF_SRC_DIR}/leil-metalogger.cfg" "${TARGET_CONF_DIR}/leil-metalogger.cfg"
		echo "Default leil-metalogger.cfg copied."
	else
		echo "ERROR: Default configuration source file '${DEFAULT_CONF_SRC_DIR}/leil-metalogger.cfg' does not exist."
		exit 1
	fi
else
	echo "Existing '${TARGET_CONF_DIR}/leil-metalogger.cfg' found."
fi

# Ensure MASTER_HOST points to the master. Without an override, a fresh
# configuration uses 'master', the hostname of the service container
# running the master, and an existing one is left as it is.
if [ -n "${MASTER_HOST}" ]; then
    echo "Setting MASTER_HOST to '${MASTER_HOST}' in leil-metalogger.cfg"
    sed -i '/^[[:space:]]*MASTER_HOST[[:space:]]*=/d' "${TARGET_CONF_DIR}/leil-metalogger.cfg"
    echo "MASTER_HOST = ${MASTER_HOST}" >> "${TARGET_CONF_DIR}/leil-metalogger.cfg"
elif ! grep -q '^[[:space:]]*MASTER_HOST[[:space:]]*=' "${TARGET_CONF_DIR}/leil-metalogger.cfg" \
    && grep -q '^# *MASTER_HOST *= *sfsmaster' "${TARGET_CONF_DIR}/leil-metalogger.cfg"; then
    echo "Setting MASTER_HOST to 'master' in leil-metalogger.cfg"
    sed -i 's/^# *MASTER_HOST *= *sfsmaster/MASTER_HOST = master/' "${TARGET_CONF_DIR}/leil-metalogger.cfg"
fi

mkdir -p "${TARGET_DATA_DIR}"

# Set ownership
echo "Setting final ownership for '${TARGET_CONF_DIR}' and '${TARGET_DATA_DIR}' to '${SAUNAFS_USER}'..."
chown -R "${SAUNAFS_USER}:${SAUNAFS_USER}" "${TARGET_CONF_DIR}"
chown -R "${SAUNAFS_USER}:${SAUNAFS_USER}" "${TARGET_DATA_DIR}"

echo "Starting LeilFS Metalogger..."
# Replace shell with leil-metalogger process
exec leil-metalogger -d -u
