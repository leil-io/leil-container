#! /bin/bash

set -e # Exit immediately if a command exits with a non-zero status.

TARGET_CONF_DIR="/etc/saunafs"
MASTER_CONF_SRC_DIR="/usr/share/doc/saunafs-master/examples"
URAFT_CONF_SRC_DIR="/usr/share/doc/saunafs-uraft/examples"
MASTER_CFG="${TARGET_CONF_DIR}/leil-master.cfg"
URAFT_CFG="${TARGET_CONF_DIR}/leil-uraft.cfg"
TARGET_DATA_DIR="/var/lib/saunafs"
# Path in the image where the Dockerfile copied the pristine metadata.sfs.empty
IMAGE_METADATA_TEMPLATE_PATH="/opt/saunafs/templates/metadata.sfs.empty"
SAUNAFS_USER="saunafs"

# Node settings, see README.md for their meaning
URAFT_FLOATING_NETMASK="${URAFT_FLOATING_NETMASK:-255.255.255.0}"
URAFT_FLOATING_IFACE="${URAFT_FLOATING_IFACE:-eth0}"
URAFT_ELECTOR_MODE="${URAFT_ELECTOR_MODE:-0}"

for required in URAFT_ID URAFT_NODES URAFT_FLOATING_IP ADMIN_PASSWORD; do
	if [ -z "${!required}" ]; then
		echo "ERROR: ${required} environment variable must be set."
		exit 1
	fi
done

# Replaces every active '<key> = ...' line in a config file with the given values
set_cfg() {
	local file="$1"
	local key="$2"
	shift 2

	sed -i "/^[[:space:]]*${key}[[:space:]]*=/d" "${file}"
	for value in "$@"; do
		echo "${key} = ${value}" >> "${file}"
	done
}

# leil-uraft and leil-uraft-helper only log through syslog, so without a
# syslog daemon in the container they fail without any output.
rm -f /dev/log
busybox syslogd -n -O /dev/stdout &
sleep 1

echo "Ensuring LeilFS uRaft directories and configurations..."

mkdir -p "${TARGET_CONF_DIR}"

if [ ! -f "${MASTER_CFG}" ]; then
	echo "'${MASTER_CFG}' not found. Copying default configurations from '${MASTER_CONF_SRC_DIR}'..."
	if [ -d "${MASTER_CONF_SRC_DIR}" ] && [ "$(ls -A "${MASTER_CONF_SRC_DIR}")" ]; then
		cp -av "${MASTER_CONF_SRC_DIR}/." "${TARGET_CONF_DIR}/"
	else
		echo "ERROR: Default configuration source directory '${MASTER_CONF_SRC_DIR}' is empty or does not exist. Check package installation and unminimize."
		exit 1
	fi
fi

if [ ! -f "${URAFT_CFG}" ]; then
	echo "'${URAFT_CFG}' not found. Copying default from '${URAFT_CONF_SRC_DIR}'..."
	if [ -f "${URAFT_CONF_SRC_DIR}/leil-uraft.cfg" ]; then
		cp -v "${URAFT_CONF_SRC_DIR}/leil-uraft.cfg" "${URAFT_CFG}"
	else
		echo "ERROR: Default '${URAFT_CONF_SRC_DIR}/leil-uraft.cfg' not found. Please check LeilFS package installation."
		exit 1
	fi
fi

echo "Applying uRaft node settings (node ${URAFT_ID}, floating IP ${URAFT_FLOATING_IP})..."
IFS=',' read -r -a uraft_nodes <<< "${URAFT_NODES}"
set_cfg "${URAFT_CFG}" URAFT_NODE_ADDRESS "${uraft_nodes[@]}"
set_cfg "${URAFT_CFG}" URAFT_ID "${URAFT_ID}"
set_cfg "${URAFT_CFG}" URAFT_ELECTOR_MODE "${URAFT_ELECTOR_MODE}"
set_cfg "${URAFT_CFG}" LOCAL_MASTER_ADDRESS localhost
set_cfg "${URAFT_CFG}" URAFT_FLOATING_IP "${URAFT_FLOATING_IP}"
set_cfg "${URAFT_CFG}" URAFT_FLOATING_NETMASK "${URAFT_FLOATING_NETMASK}"
set_cfg "${URAFT_CFG}" URAFT_FLOATING_IFACE "${URAFT_FLOATING_IFACE}"

# The master refuses to start under uRaft unless its own configuration
# agrees, and shadows follow whichever node holds the floating IP.
set_cfg "${MASTER_CFG}" PERSONALITY ha-cluster-managed
set_cfg "${MASTER_CFG}" MASTER_HOST "${URAFT_FLOATING_IP}"
set_cfg "${MASTER_CFG}" ADMIN_PASSWORD "${ADMIN_PASSWORD}"

# leil-uraft-helper resolves the floating IP with 'getent hosts', which
# fails for an address without a hosts entry or reverse DNS record.
if ! getent hosts "${URAFT_FLOATING_IP}" >/dev/null; then
	echo "${URAFT_FLOATING_IP} leil-uraft-floating-ip" >> /etc/hosts
fi

mkdir -p "${TARGET_DATA_DIR}"

# Initialize metadata.sfs from the image's template if the data directory (volume) is empty.
# Every node of a new cluster starts from the same empty metadata. A node
# wiped later has an older metadata version, so it cannot win an election
# and resynchronizes from the leader as a shadow.
if [ ! "$(ls -A "${TARGET_DATA_DIR}")" ]; then
	echo "Target data directory '${TARGET_DATA_DIR}' is empty. Initializing 'metadata.sfs' from image template '${IMAGE_METADATA_TEMPLATE_PATH}'..."
	cp -v "${IMAGE_METADATA_TEMPLATE_PATH}" "${TARGET_DATA_DIR}/metadata.sfs"
fi

# A lock left by an unclean shutdown blocks the master from starting.
# Recovery happens on promotion, as leil-uraft-helper starts the new
# leader with auto-recovery.
if [ -f "${TARGET_DATA_DIR}/metadata.sfs.lock" ]; then
	echo "Removing stale '${TARGET_DATA_DIR}/metadata.sfs.lock'..."
	rm -f "${TARGET_DATA_DIR}/metadata.sfs.lock"
fi

echo "Setting final ownership for '${TARGET_CONF_DIR}' and '${TARGET_DATA_DIR}' to '${SAUNAFS_USER}'..."
chown -R "${SAUNAFS_USER}:${SAUNAFS_USER}" "${TARGET_CONF_DIR}"
chown -R "${SAUNAFS_USER}:${SAUNAFS_USER}" "${TARGET_DATA_DIR}"
# It holds the admin password and stays on the volume after the container
# is gone.
chmod 600 "${MASTER_CFG}"

# Releases the floating IP before the container goes away, as a node that
# is killed while leading leaves the address behind on its interface. The
# master stops first, as without the address it cannot close its
# connections and waits for them to time out.
stop_node() {
	if kill -0 "${URAFT_PID}" 2>/dev/null; then
		kill -TERM "${URAFT_PID}"
		wait "${URAFT_PID}" || true
	fi
	leil-uraft-helper stop-saunafs-ha-master || true
	leil-uraft-helper drop-ip || true
}

# uRaft only supervises the master, so it must already be running as a
# shadow (systemd orders this through saunafs-ha-master.service). The
# helper skips it on elector nodes, where it returns 0, and only fails
# when the master cannot start, so the node could never lead.
echo "Starting LeilFS Master as shadow..."
if ! leil-uraft-helper start-saunafs-ha-master; then
	echo "ERROR: LeilFS Master failed to start; see the leil-uraft-helper messages above."
	exit 1
fi

echo "Starting LeilFS uRaft..."
leil-uraft -c "${URAFT_CFG}" &
URAFT_PID=$!
trap 'echo "Stopping LeilFS uRaft..."; stop_node; exit 0' TERM INT

status=0
wait "${URAFT_PID}" || status=$?
echo "leil-uraft exited with status ${status}."
stop_node
exit "${status}"
