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
# Hosts, IP addresses or networks (CIDR) that may mount read-write, comma
# separated, or '*' for any host. Without it, any host may mount read-only.
NFS_CLIENTS="${NFS_CLIENTS:-}"

GANESHA_CONF="/etc/ganesha/ganesha.conf"
# Client state for the grace period after a restart; keep it on a volume
RECOVERY_DIR="/var/lib/nfs/ganesha"
PID_FILE="/var/run/ganesha/ganesha.pid"

if [[ ! "${NFS_PROTOCOLS}" =~ ^[34]([[:space:]]*,[[:space:]]*[34])?$ ]]; then
	echo "ERROR: NFS_PROTOCOLS must be 4, 3 or '3, 4', not '${NFS_PROTOCOLS}'."
	exit 1
fi

# Only characters of host names, addresses, networks and netgroups, so the
# value cannot end the configuration block it goes into
if [[ ! "${NFS_CLIENTS}" =~ ^[[:alnum:].:/*@_,[:space:]-]*$ ]]; then
	echo "ERROR: NFS_CLIENTS must be a comma-separated list of hosts, addresses or networks, not '${NFS_CLIENTS}'."
	exit 1
fi

# The export trusts root on its clients (see Squash below), so who may
# write is NFS_CLIENTS: the listed hosts read-write and no one else, any
# host read-write with '*', or any host read-only when it is not set.
CLIENT_BLOCK=""
if [[ ! "${NFS_CLIENTS}" =~ [^[:space:],] ]]; then
	EXPORT_ACCESS="RO"
	ACCESS_DESCRIPTION="read-only for any host"
elif [[ "${NFS_CLIENTS}" =~ ^[[:space:]]*\*[[:space:]]*$ ]]; then
	EXPORT_ACCESS="RW"
	ACCESS_DESCRIPTION="read-write for any host"
else
	EXPORT_ACCESS="None"
	ACCESS_DESCRIPTION="read-write for ${NFS_CLIENTS} only"
	CLIENT_BLOCK="
    CLIENT {
        Clients = ${NFS_CLIENTS};
        Access_Type = RW;
    }
"
fi

mkdir -p /etc/ganesha "${RECOVERY_DIR}" "$(dirname "${PID_FILE}")"

if [ ! -f "${GANESHA_CONF}" ]; then
	echo "'${GANESHA_CONF}' not found. Writing it for ${MASTER_HOST}:${MASTER_PORT}, NFS ${NFS_PROTOCOLS}, ${ACCESS_DESCRIPTION}..."
	if [ "${EXPORT_ACCESS}" = RO ]; then
		echo "WARNING: NFS_CLIENTS is not set, so LeilFS is exported read-only to any host that reaches this gateway. Set it to the NFS clients that may write."
	fi
	cat > "${GANESHA_CONF}" <<EOF
# Written by leil-nfs-ganesha.start.sh from its environment. Mount your own
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

    Access_Type = ${EXPORT_ACCESS};
    # Root on the clients is root in LeilFS: the LeilFS FSAL creates
    # files as root for squashed users, so squashing breaks writes
    # without protecting anything. Restrict the clients instead.
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
${CLIENT_BLOCK}}
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

# -x: exit when the configuration has errors, which includes an export the
# FSAL could not create, e.g. as the master was not reachable yet. Ganesha
# would otherwise keep serving NFS without LeilFS; exiting lets the
# container's restart policy retry. The LeilFS FSAL of 5.12 crashes when it
# cannot reach the master at all (an exception escapes it), immediately
# when the connection is refused and within minutes when nothing answers,
# which ends in the same restart.
echo "Starting NFS-Ganesha..."
ganesha.nfsd -v
exec ganesha.nfsd -F -x -L STDOUT -f "${GANESHA_CONF}" -p "${PID_FILE}"
