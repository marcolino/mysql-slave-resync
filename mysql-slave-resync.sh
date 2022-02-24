#!/usr/bin/env bash
#
# Script to resync one or more MySQL slave replication databases with their master.
# Must be run on master host, by a user with maser database access.
# Will connect securely to slave host to perform slave resync.
#
# Logical steps:
#  - check disk space on master server
#  - reset and read-lock master db
#  - dump master db
#  - unlock master db
#  - check disk space on slave server
#  - copy dump to slave server
#  - stop slave db
#  - increase max allowed packets on slave db
#  - restore dump to slave db
#  - reset slave db to master log file and position
#  - start slave db
#  - check slave db status
#  - clean up temporary files on slave server
#
# (see https://stackoverflow.com/a/3229580/709439)
#
#####################################################################################

#####################################################################################
# Section to be parametrized before use
#####################################################################################
SLAVE_HOST="" # slave host (i.e.: "db.example.com")
SLAVE_USER="" # slave user
SLAVE_PASS="" # slave password
#####################################################################################

DBS="$*"
TMP="/tmp/mysql-slave-resync"

mkdir -p "${TMP}"

if [ -z "${SLAVE_HOST}" -o -z "${SLAVE_USER}" -o -z "${SLAVE_PASS}" ]; then
  cat <<EOT
Please set SLAVE_HOST, SLAVE_USER and SLAVE_PASS variables in script before run.
EOT
  exit -1
fi

if [ -z "${DBS}" ]; then
  cat <<EOT
Usage:  `basename $0`  DB1 [ DB2 ... DBn ]

Resync a MySQL slave replication database.
Must be run on master host.
Will connect securely to slave host to perform slave resync.
EOT
  exit -1
fi

echo "Master: ${USER}@localhost"
echo "Slave: ${SLAVE_USER}@${SLAVE_HOST}"
echo "Databases to resync: ${DBS}"
echo

(
for DB in $DBS; do
  echo "Resync database "$(tput bold)"$DB"$(tput sgr0)

  echo " - checking disk space on master server"
  ( echo -ne '    - '; df -h "${TMP}" | cut -c28-32 | tr -d '\n'; echo )

  echo " - resetting and read-locking master db"
  cat <<EOT | mysql --login-path=local "$DB" > "${TMP}/${DB}-master.status"
RESET MASTER;
FLUSH TABLES WITH READ LOCK;
SHOW MASTER STATUS;
EOT
  if [ $? -ne 0 ]; then echo "error"; exit -1; fi
  MASTER_LOG_FILE=`cat "${TMP}/${DB}-master.status" | tail -1 | cut -f 1`
  MASTER_LOG_POS=`cat "${TMP}/${DB}-master.status" | tail -1 | cut -f 2`
  echo "    - MASTER_LOG_FILE: $MASTER_LOG_FILE"
  echo "    - MASTER_LOG_POS: $MASTER_LOG_POS"

  echo " - dumping master db"
  mysqldump --login-path=local "$DB" | gzip > "${TMP}/${DB}.sql.gz"
  if [ $? -ne 0 ]; then echo "error"; exit -1; fi

  echo " - unlocking master db"
  cat <<EOT | mysql --login-path=local "$DB"
UNLOCK TABLES;
EOT
  if [ $? -ne 0 ]; then echo "error"; exit -1; fi

  echo " - checking disk space on slave server"
  su - "$SLAVE_USER" -c "ssh \"${SLAVE_HOST}\" \"\
( echo -ne '    - '; df -h /tmp | cut -c28-32 | tr -d '\n'; echo )
\""
  if [ $? -ne 0 ]; then echo "error $?"; exit -1; fi

  echo " - copying dump to slave server"
  su - "$SLAVE_USER" -c "scp \"${TMP}/${DB}.sql.gz\" \"${SLAVE_HOST}:/tmp\""
  if [ $? -ne 0 ]; then echo "error $?"; exit -1; fi

  echo " - stopping slave db"
  su - "$SLAVE_USER" -c "ssh \"${SLAVE_HOST}\" \"\
cat <<EOT | mysql -u root -p'${SLAVE_PASS}' "$DB"
STOP SLAVE;
EOT
\""
  if [ $? -ne 0 ]; then echo "error"; exit -1; fi

  echo " - increasing max allowed packets on slave db"
  su - "$SLAVE_USER" -c "ssh \"${SLAVE_HOST}\" \"\
cat <<EOT | mysql -u root -p'${SLAVE_PASS}' "$DB"
SET global net_buffer_length=1000000; 
SET global max_allowed_packet=1000000000;
EOT
\""
  if [ $? -ne 0 ]; then echo "error"; exit -1; fi

  echo " - restoring dump to slave db"
  su - "$SLAVE_USER" -c "ssh \"${SLAVE_HOST}\" \"\
zcat /tmp/${DB}.sql.gz | mysql -u root -p'${SLAVE_PASS}' "$DB"
\""
  if [ $? -ne 0 ]; then echo "error"; exit -1; fi

  echo " - resetting slave db to master log file and position"
  su - "$SLAVE_USER" -c "ssh \"${SLAVE_HOST}\" \"\
cat <<EOT | mysql -u root -p'${SLAVE_PASS}' "$DB"
RESET SLAVE;
CHANGE MASTER TO MASTER_LOG_FILE='$MASTER_LOG_FILE', MASTER_LOG_POS=$MASTER_LOG_POS;
EOT
\""
  if [ $? -ne 0 ]; then echo "error"; exit -1; fi

  echo " - starting slave db"
  su - "$SLAVE_USER" -c "ssh \"${SLAVE_HOST}\" \"\
cat <<EOT | mysql -u root -p'${SLAVE_PASS}' "$DB"
START SLAVE;
EOT
\""
  if [ $? -ne 0 ]; then echo "error"; exit -1; fi

  echo " - checking db status"
  su - "$SLAVE_USER" -c "ssh \"${SLAVE_HOST}\" \"\
cat <<EOT | mysql -u root -p'${SLAVE_PASS}' "$DB"
SHOW SLAVE STATUS \G
EOT
\"" > "${TMP}/status"
  if [ $? -ne 0 ]; then echo "error"; exit -1; fi
  grep "_Running:" "${TMP}/status"
  rm -f "${TMP}/status"

  echo " - cleaning up temporary files on slave server"
  su - "$SLAVE_USER" -c "ssh \"${SLAVE_HOST}\" \"\
rm -f '/tmp/${DB}.sql.gz'
\""
  if [ $? -ne 0 ]; then echo "error"; exit -1; fi

  rm -f "${TMP}/${DB}.sql.gz"

  echo
done
) 2>&1 | grep -v "Using a password"
