#! /bin/bash

set -e # Exit immediately if a command exits with a non-zero status.

TARGET_CONF_DIR="/etc/saunafs"
DEFAULT_CONF_SRC_DIR="/usr/share/doc/saunafs-chunkserver/examples"
TARGET_DATA_DIR="/var/lib/saunafs" # For chunkserver's own operational data/logs, if any
SAUNAFS_USER="saunafs"

CONFIGURED_HDD_PATHS=()

echo "Ensuring LeilFS Chunkserver directories and configurations..."

mkdir -p "${TARGET_CONF_DIR}"

# Copy default sfschunkserver.cfg if not present
if [ ! -f "${TARGET_CONF_DIR}/sfschunkserver.cfg" ]; then
	echo "'${TARGET_CONF_DIR}/sfschunkserver.cfg' not found. Copying default from '${DEFAULT_CONF_SRC_DIR}'..."
	if [ -f "${DEFAULT_CONF_SRC_DIR}/sfschunkserver.cfg" ]; then
		cp -v "${DEFAULT_CONF_SRC_DIR}/sfschunkserver.cfg" "${TARGET_CONF_DIR}/sfschunkserver.cfg"
	else
		echo "ERROR: Default '${DEFAULT_CONF_SRC_DIR}/sfschunkserver.cfg' not found. Please check LeilFS package installation."
		exit 1
	fi
fi

# Ensure MASTER_HOST points to the correct service name.
# This is needed because 'master' is the hostname of the service container running the master.
if grep -q '^# *MASTER_HOST *= *sfsmaster' "${TARGET_CONF_DIR}/sfschunkserver.cfg"; then
    echo "Setting MASTER_HOST to 'master' in sfschunkserver.cfg"
    sed -i 's/^# *MASTER_HOST *= *sfsmaster/MASTER_HOST = master/' "${TARGET_CONF_DIR}/sfschunkserver.cfg"
fi

# Always ensure a base sfshdd.cfg is present, copy from default if not there.
# The script will then overwrite it with detected/configured HDDs.
if [ ! -f "${TARGET_CONF_DIR}/sfshdd.cfg" ]; then
	echo "'${TARGET_CONF_DIR}/sfshdd.cfg' not found. Copying default from '${DEFAULT_CONF_SRC_DIR}'..."
	if [ -f "${DEFAULT_CONF_SRC_DIR}/sfshdd.cfg" ]; then
		cp -v "${DEFAULT_CONF_SRC_DIR}/sfshdd.cfg" "${TARGET_CONF_DIR}/sfshdd.cfg"
	else
		# If no default, create an empty one, as chunkserver might be ok with it or we'll populate it.
		echo "WARNING: Default '${DEFAULT_CONF_SRC_DIR}/sfshdd.cfg' not found. Creating an empty one."
		touch "${TARGET_CONF_DIR}/sfshdd.cfg"
	fi
fi

echo "Detecting and configuring HDD paths from /mnt/hdd* ..."
CONFIGURED_HDD_PATHS=()

# Use process substitution to read find's output in the current shell context
# This ensures CONFIGURED_HDD_PATHS is modified in the main shell, not a subshell.
while IFS= read -r -d $'\0' hdd_path; do
	if [ -z "${hdd_path}" ]; then # Skip if path is empty (should not happen with find -print0)
		continue
	fi
	
	echo "Processing potential HDD path: '${hdd_path}'"

	# Check if it's a mount point to provide appropriate info/warning
	if findmnt -M "${hdd_path}" >/dev/null 2>&1; then
		echo "INFO: '${hdd_path}' is a mount point. Assuming persistent storage provided by user."
	else
		echo "WARNING: '${hdd_path}' is not a mount point. Using as volatile storage. Data in this path WILL BE LOST when the container stops."
	fi
	
	CONFIGURED_HDD_PATHS+=("${hdd_path}")
done < <(find /mnt -maxdepth 1 -type d -name "hdd*" -print0 2>/dev/null || true)


if [ ${#CONFIGURED_HDD_PATHS[@]} -eq 0 ]; then
	echo "INFO: No HDD paths matching /mnt/hdd* were found or configured. Chunkserver will start without pre-configured disks. sfshdd.cfg will be minimal."
	# Create an empty sfshdd.cfg or ensure it's empty if no HDDs found
	# The default example sfshdd.cfg might contain example paths, so we clear it.
	echo "# No /mnt/hdd* paths found or configured." > "${TARGET_CONF_DIR}/sfshdd.cfg"
	echo "# Chunkserver will start without disks, or use internal defaults if any." >> "${TARGET_CONF_DIR}/sfshdd.cfg"
else
	echo "Updating '${TARGET_CONF_DIR}/sfshdd.cfg' with configured HDD paths..."
	# Clear the sfshdd.cfg and add the detected/created paths
	> "${TARGET_CONF_DIR}/sfshdd.cfg"
	for hdd_path in "${CONFIGURED_HDD_PATHS[@]}"; do
		echo "${hdd_path}" >> "${TARGET_CONF_DIR}/sfshdd.cfg"
	done
fi
echo "Current sfshdd.cfg content:"
cat "${TARGET_CONF_DIR}/sfshdd.cfg"

mkdir -p "${TARGET_DATA_DIR}"

echo "Setting final ownership for LeilFS directories and HDD paths to '${SAUNAFS_USER}'..."
chown -R "${SAUNAFS_USER}:${SAUNAFS_USER}" "${TARGET_CONF_DIR}"
chown -R "${SAUNAFS_USER}:${SAUNAFS_USER}" "${TARGET_DATA_DIR}"

# Only chown paths that were actually configured and exist
if [ ${#CONFIGURED_HDD_PATHS[@]} -gt 0 ]; then
	for hdd_path in "${CONFIGURED_HDD_PATHS[@]}"; do
		if [ -d "${hdd_path}" ]; then
			chown -R "${SAUNAFS_USER}:${SAUNAFS_USER}" "${hdd_path}"
		else
			echo "WARNING: HDD path '${hdd_path}' configured but directory does not exist. Skipping chown."
		fi
	done
fi

echo "Starting LeilFS Chunkserver..."
# Consider using su-exec to drop privileges to saunafs user if sfschunkserver doesn't do it itself
# exec su-exec "${SAUNAFS_USER}" sfschunkserver -d -u
exec sfschunkserver -d -u
