#! /bin/bash

set -e # Exit immediately if a command exits with a non-zero status.

# NFS-Ganesha exporting LeilFS through the LeilFS FSAL.
#
# Without /etc/ganesha/ganesha.conf (e.g. from a volume), one is written
# from these settings, see README.md:
MASTER_HOST="${MASTER_HOST:-master}"
MASTER_PORT="${MASTER_PORT:-9421}"
NFS_PROTOCOLS="${NFS_PROTOCOLS:-4}"
EXPORT_PATH="${EXPORT_PATH:-/}"
PSEUDO_PATH="${PSEUDO_PATH:-/}"

GANESHA_CONF="/etc/ganesha/ganesha.conf"
# Client state for the grace period after a restart; keep it on a volume
RECOVERY_DIR="/var/lib/nfs/ganesha"
PID_FILE="/var/run/ganesha/ganesha.pid"

if [[ ! "${NFS_PROTOCOLS}" =~ ^[34]([[:space:]]*,[[:space:]]*[34])?$ ]]; then
	echo "ERROR: NFS_PROTOCOLS must be 4, 3 or '3, 4', not '${NFS_PROTOCOLS}'."
	exit 1
fi

mkdir -p /etc/ganesha "${RECOVERY_DIR}" "$(dirname "${PID_FILE}")"

if [ ! -f "${GANESHA_CONF}" ]; then
	echo "'${GANESHA_CONF}' not found. Writing it for ${MASTER_HOST}:${MASTER_PORT}, NFS ${NFS_PROTOCOLS}..."
	cat > "${GANESHA_CONF}" <<EOF
# Written by leil-ganesha.start.sh from its environment. Mount your own
# ${GANESHA_CONF} to change anything else.

NFS_CORE_PARAM
{
    Protocols = ${NFS_PROTOCOLS};
    # NFSv3 mounts through MNT, on a fixed port for firewalls
    MNT_Port = 20048;
    # NLM needs rpc.statd, which this image does not run, so NFSv3
    # clients cannot lock files; NFSv4 has locking built in.
    Enable_NLM = false;
    Enable_RQUOTA = false;
    # PR_SET_IO_FLUSHER needs CAP_SYS_RESOURCE, which Docker does not
    # grant by default. It only guards against memory-reclaim deadlocks
    # when the server mounts its own export, which a gateway does not.
    allow_set_io_flusher_fail = true;
}

NFSv4
{
    RecoveryBackend = fs;
    RecoveryRoot = "${RECOVERY_DIR}";
}

EXPORT
{
    # Export Id (mandatory, each EXPORT must have a unique Export_Id)
    Export_Id = 77;

    # Exported path (mandatory)
    Path = "${EXPORT_PATH}";

    # Pseudo Path (required for NFS v4)
    Pseudo = "${PSEUDO_PATH}";

    Access_Type = RW;
    Squash = None;
    Attr_Expiration_Time = 0;

    FSAL {
        Name = SaunaFS;
        # The address of the LeilFS master, or the floating IP with uRaft
        hostname = "${MASTER_HOST}";
        port = ${MASTER_PORT};
        # How often to retry to connect
        io_retries = 5;
        cache_expiration_time_ms = 2500;
    }

    Protocols = ${NFS_PROTOCOLS};
}
EOF
else
	echo "Existing '${GANESHA_CONF}' found."
fi

# Ganesha registers its services with rpcbind, which NFSv3 clients need
# to find them, and which some Ganesha releases fail to start without even
# for NFSv4. With the host's network, the host's rpcbind is used when it
# runs.
if rpcinfo -p 127.0.0.1 >/dev/null 2>&1; then
	echo "Using the running rpcbind."
else
	echo "Starting rpcbind..."
	rpcbind -w
fi

# A pid file left by a container that was killed would stop Ganesha
rm -f "${PID_FILE}"

echo "Starting NFS-Ganesha..."
ganesha.nfsd -v
exec ganesha.nfsd -F -L STDOUT -f "${GANESHA_CONF}" -p "${PID_FILE}"
