#!/usr/bin/env bash
set -euo pipefail

read -r -p "DB server host (passwordless SSH): " DB_SERVER
if [[ -z "${DB_SERVER}" ]]; then
  echo "DB server is required." >&2
  exit 1
fi

read -r -p "SSH user (oracle, NIS user id, or root): " SSH_USER
if [[ -z "${SSH_USER}" ]]; then
  echo "SSH user is required." >&2
  exit 1
fi

read -r -p "DB name (srvctl -d): " DB_NAME
if [[ -z "${DB_NAME}" ]]; then
  echo "DB name is required." >&2
  exit 1
fi

read -r -p "oracle_home path: " oracle_home
if [[ -z "${oracle_home}" ]]; then
  echo "oracle_home is required." >&2
  exit 1
fi

oracle_sid="$(echo "${DB_NAME}" | tr '[:upper:]' '[:lower:]')1"

read -r -p "DB action (start/stop/bounce/skip): " DB_ACTION
DB_ACTION=$(echo "${DB_ACTION}" | tr '[:upper:]' '[:lower:]')
if [[ "${DB_ACTION}" != "start" && "${DB_ACTION}" != "stop" && "${DB_ACTION}" != "bounce" && "${DB_ACTION}" != "skip" ]]; then
  echo "DB action must be start, stop, bounce, or skip." >&2
  exit 1
fi

PDB_ACTION="skip"
PDB_NAME=""
DROP_DATAFILES=""
if [[ "${DB_ACTION}" == "bounce" ]]; then
  # Default behavior for bounce: open all PDBs without prompting.
  PDB_ACTION="open"
  PDB_NAME="ALL"
else
  read -r -p "PDB action (open/close/drop/skip): " PDB_ACTION
  PDB_ACTION=$(echo "${PDB_ACTION}" | tr '[:upper:]' '[:lower:]')
  if [[ "${PDB_ACTION}" != "open" && "${PDB_ACTION}" != "close" && "${PDB_ACTION}" != "drop" && "${PDB_ACTION}" != "skip" ]]; then
    echo "PDB action must be open, close, drop, or skip." >&2
    exit 1
  fi

  if [[ "${PDB_ACTION}" != "skip" ]]; then
    if [[ "${PDB_ACTION}" == "drop" ]]; then
      read -r -p "PDB name to drop: " PDB_NAME
      if [[ -z "${PDB_NAME}" ]]; then
        echo "PDB name is required for drop." >&2
        exit 1
      fi
      read -r -p "Drop including datafiles? (yes/no): " DROP_DATAFILES
      DROP_DATAFILES=$(echo "${DROP_DATAFILES}" | tr '[:upper:]' '[:lower:]')
      if [[ "${DROP_DATAFILES}" != "yes" && "${DROP_DATAFILES}" != "no" ]]; then
        echo "Drop including datafiles must be yes or no." >&2
        exit 1
      fi
    else
      read -r -p "PDB name (leave blank for ALL): " PDB_NAME
    fi
  fi
fi

LOG_FILE="./db_start_stop_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "Logging to ${LOG_FILE}"

SSH_OPTS=( -o BatchMode=yes )
SSH_TARGET="${SSH_USER}@${DB_SERVER}"
REMOTE_ENV="export ORACLE_HOME='${oracle_home}'; export ORACLE_SID='${oracle_sid}'; export PATH='${oracle_home}/bin:${PATH}';"

echo "Checking for srvctl on ${DB_SERVER}"
if ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} command -v srvctl >/dev/null 2>&1"; then
  USE_SRVCTL="yes"
  echo "srvctl detected; will use srvctl for DB start/stop."
else
  USE_SRVCTL="no"
  echo "srvctl not detected; will use sqlplus startup/shutdown for DB start/stop."
fi

echo "Checking sqlplus connectivity on ${DB_SERVER} as ${SSH_USER} with ORACLE_SID=${oracle_sid}"
if ! ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} sqlplus -s / as sysdba <<'SQL'
EXIT;
SQL"; then
  read -r -p "Unable to connect with ORACLE_SID=${oracle_sid}. Enter correct SID: " oracle_sid
  if [[ -z "${oracle_sid}" ]]; then
    echo "oracle_sid is required." >&2
    exit 1
  fi
  oracle_sid="$(echo "${oracle_sid}" | tr '[:upper:]' '[:lower:]')"
  REMOTE_ENV="export ORACLE_HOME='${oracle_home}'; export ORACLE_SID='${oracle_sid}'; export PATH='${oracle_home}/bin:${PATH}';"
fi

if [[ "${DB_ACTION}" == "bounce" ]]; then
  if [[ "${USE_SRVCTL}" == "yes" ]]; then
    echo "Running: srvctl stop database -d ${DB_NAME} on ${DB_SERVER} as ${SSH_USER}"
    ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} srvctl stop database -d ${DB_NAME}"
    echo "Checking DB status on ${DB_SERVER} as ${SSH_USER}"
    ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} srvctl status database -d ${DB_NAME}"
    echo "Running: srvctl start database -d ${DB_NAME} on ${DB_SERVER} as ${SSH_USER}"
    ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} srvctl start database -d ${DB_NAME}"
    echo "Checking DB status on ${DB_SERVER} as ${SSH_USER}"
    ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} srvctl status database -d ${DB_NAME}"
  else
    echo "Running: sqlplus shutdown/startup on ${DB_SERVER} as ${SSH_USER}"
    ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} sqlplus / as sysdba <<'SQL'
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT;
SQL"
  fi
elif [[ "${DB_ACTION}" != "skip" ]]; then
  if [[ "${USE_SRVCTL}" == "yes" ]]; then
    echo "Running: srvctl ${DB_ACTION} database -d ${DB_NAME} on ${DB_SERVER} as ${SSH_USER}"
    ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} srvctl ${DB_ACTION} database -d ${DB_NAME}"
    echo "Checking DB status on ${DB_SERVER} as ${SSH_USER}"
    ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} srvctl status database -d ${DB_NAME}"
  else
    if [[ "${DB_ACTION}" == "stop" ]]; then
      echo "Running: sqlplus shutdown immediate on ${DB_SERVER} as ${SSH_USER}"
      ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} sqlplus / as sysdba <<'SQL'
SHUTDOWN IMMEDIATE;
EXIT;
SQL"
    else
      echo "Running: sqlplus startup on ${DB_SERVER} as ${SSH_USER}"
      ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} sqlplus / as sysdba <<'SQL'
STARTUP;
EXIT;
SQL"
    fi
  fi
fi

if [[ "${PDB_ACTION}" != "skip" ]]; then
  if [[ -z "${PDB_NAME}" || "${PDB_NAME^^}" == "ALL" ]]; then
    PDB_NAME="ALL"
    if [[ "${PDB_ACTION}" == "close" ]]; then
      PDB_SQL="ALTER PLUGGABLE DATABASE ALL CLOSE IMMEDIATE INSTANCES=ALL;"
    else
      PDB_SQL="ALTER PLUGGABLE DATABASE ALL OPEN INSTANCES=ALL;"
    fi
  else
    if [[ "${PDB_ACTION}" == "close" ]]; then
      PDB_SQL="ALTER PLUGGABLE DATABASE ${PDB_NAME} CLOSE IMMEDIATE INSTANCES=ALL;"
    elif [[ "${PDB_ACTION}" == "drop" ]]; then
      if [[ "${DROP_DATAFILES}" == "yes" ]]; then
        DROP_SQL="DROP PLUGGABLE DATABASE ${PDB_NAME} INCLUDING DATAFILES;"
      else
        DROP_SQL="DROP PLUGGABLE DATABASE ${PDB_NAME} KEEP DATAFILES;"
      fi
      PDB_SQL="ALTER PLUGGABLE DATABASE ${PDB_NAME} CLOSE IMMEDIATE INSTANCES=ALL;
${DROP_SQL}"
    else
      PDB_SQL="ALTER PLUGGABLE DATABASE ${PDB_NAME} OPEN READ WRITE INSTANCES=ALL;"
    fi
  fi

  echo "Running: ${PDB_ACTION} for PDB ${PDB_NAME} on ${DB_SERVER} as ${SSH_USER}"
  ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} sqlplus / as sysdba <<'SQL'
${PDB_SQL}
EXIT;
SQL"
fi

echo "Listing PDBs on ${DB_SERVER} as ${SSH_USER}"
ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_ENV} sqlplus / as sysdba <<'SQL'
SHOW PDBS;
EXIT;
SQL"

echo "Done."
