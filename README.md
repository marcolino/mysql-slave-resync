# mysql-slave-resync.sh

Script to resync one or more MySQL slave replication databases with their master.  
Must be run on master host, by a user with maser database access.  
Will connect securely to slave host to perform slave resync.  

Logical steps:  
 - check disk space on master server
 - reset and read-lock master db
 - dump master db
 - unlock master db
 - check disk space on slave server
 - copy dump to slave server
 - stop slave db
 - increase max allowed packets on slave db
 - restore dump to slave db
 - reset slave db to master log file and position
 - start slave db
 - check slave db status
 - clean up temporary files on slave server

(see https://stackoverflow.com/a/3229580/709439)