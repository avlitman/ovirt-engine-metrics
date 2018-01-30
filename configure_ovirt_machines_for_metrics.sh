#!/bin/sh

usage() {
	cat << __EOF__
Usage: $0

  --playbook=PLAYBOOK
        PLAYBOOK, the name of the playbook to run, is one of:
        ${PLAYBOOK}, manage-ovirt-metrics-services.yml, setup-metrics-store.yml.
        Default is ${PLAYBOOK}.
  --scope=SCOPE
        SCOPE is one of 'hosts', 'engine', 'all'.
        Default is 'all'.
  --log=FILE
        Write the log also to FILE.
        Default is to a file inside ${LOG_DIR}.

  Available params for manage-ovirt-metrics-services.yml playbook:
  -e service_state=SERVICE_STATE
        SERVICE_STATE is one of 'started', 'restarted', 'stopped', 'reloaded'.
        Default is 'restarted'.
  -e service_name=SERVICE_NAME
        SERVICE_NAME is a list of the services that will be managed by the role.
        Default is ["collectd", "fluentd"].
  -e service_enabled=SERVICE_ENABLED
        SERVICE_ENABLED is used to configure if the processes will be enabled.
        Default is 'yes'.

  Other ansible playbook parameters are passed to the ansible-playbook.
__EOF__
	exit 1
}

script_path="$(readlink -f "$0")"
cd "$(dirname "$script_path")"

MY_BIN_DIR="${PWD}/bin"
. "${MY_BIN_DIR}"/config.sh

 if ! [ -d "${ENGINE_DATA_DIR}" ]; then
         echo "$0 can only be used on the engine machine. Please install this package on your engine machine and run it there"
         exit 1
 fi

. "${ENGINE_DATA_BIN_DIR}"/engine-prolog.sh

# Older engines didn't expose ENGINE_LOG, set a default
[ -z "${ENGINE_LOG}" ] && ENGINE_LOG=/var/log/ovirt-engine

LOG_DIR="${ENGINE_LOG}/ansible"

# Should already exist in oVirt 4.2, but create if needed anyway
mkdir -p "${LOG_DIR}"

timestamp="$(date +"%Y%m%d%H%M%S")"
LOG_FILE="${LOG_DIR}/standalone-${timestamp}-ovirt-metrics-deployment.log"

SCOPE=all

PLAYBOOK=configure-ovirt-metrics.yml

COLLECTD_SYSTEMD_PG_CONF=/etc/systemd/system/collectd.service.d/postgresql.conf
CREATE_PG_PASS="${MY_BIN_DIR}"/create_collectd_pg_pass.sh

setup_db_creds() {
	COLLECTD_SYSTEMD_DIR="$(dirname ${COLLECTD_SYSTEMD_PG_CONF})"
	mkdir -p "${COLLECTD_SYSTEMD_DIR}" || die "Failed to create ${COLLECTD_SYSTEMD_DIR}"

	local tmpconf="$(mktemp)"
	cat > "${tmpconf}" << __EOF__
# This file was automatically generated by ${script_path}, do not edit manually
[Service]
ExecStartPre=${CREATE_PG_PASS}
Environment=PGHOST=${ENGINE_DB_HOST}
Environment=PGPORT=${ENGINE_DB_PORT}
Environment=PGDATABASE=${ENGINE_DB_DATABASE}
Environment=PGUSER=${ENGINE_DB_USER}
Environment=PGPASSFILE=${COLLECTD_PGPASS}
__EOF__
	[ $? == 0 ] || die "Failed to create ${tmpconf}"

	if ! cmp -s "${COLLECTD_SYSTEMD_PG_CONF}" "${tmpconf}"; then
		cat "${tmpconf}" > "${COLLECTD_SYSTEMD_PG_CONF}" || die "Failed to write ${COLLECTD_SYSTEMD_PG_CONF}"
	fi
	rm -f "${tmpconf}"

	# Required for systemd to notice
	systemctl daemon-reload
}

extra_opts=()
while [ -n "$1" ]; do
	x="$1"
	v="${x#*=}"
	shift
	case "${x}" in
		--playbook=*)
			PLAYBOOK="${v}"
		;;
		--scope=*)
			SCOPE="${v}"
		;;
		--log=*)
			LOG_FILE="${v}"
		;;
		--help|-h)
			usage
		;;
		*)
			extra_opts+="${x}"
		;;
	esac
done

# Always create collectd conf. Should be harmless if not needed.
# We could check if $SCOPE is 'engine' or 'all', but then it will
# not work if user passes some other valid ansible pattern.
setup_db_creds

export ANSIBLE_LOG_PATH="${LOG_FILE}"

ansible-playbook \
	playbooks/"${PLAYBOOK}" \
	-e ansible_ssh_private_key_file="${ENGINE_PKI}/keys/engine_id_rsa" \
	-e pg_db_name="${ENGINE_DB_DATABASE}" \
	-l "${SCOPE}" \
	"${extra_opts[@]}"
