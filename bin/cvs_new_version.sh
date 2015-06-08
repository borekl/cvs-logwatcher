#!/bin/bash

#--- decide prefix based on the scripts pathname
#--- solution from: 
#--- http://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself

SCRIPTPATH=$( cd "$(dirname "$0")" ; pwd -P )
if [[ $SCRIPTPATH =~ '/prod' ]]; then
  PREFIX=/opt/cvs/prod
else
  PREFIX=/opt/cvs/dev
fi

#---

HOST="$1"
HOST2="$2"
MSG="$3"
TYPE="$4"
DIR_REPOSIT="$PREFIX/data/$5";
IOS_TYPE="$6"

SNMP_VERSION="1";

LOG_FILE_CISCO="/var/log/cvs_cisco.log";
LOG_FILE_ALU="/var/log/cvs_alu.log";

MYIP="172.20.113.120"
MYEXTIP="217.77.161.63"

SSET="/usr/bin/snmpset"
RCS="/usr/bin/rcs"
CI="/usr/bin/ci"

if [ $TYPE = "cisco" ]
then
	echo "`date` $HOST $HOST2" >> $LOG_FILE_CISCO
else
	echo "`date` $HOST $HOST2" >> $LOG_FILE_ALU
fi


echo "BASH: `date` Hostname: $HOST"
echo "BASH: `date` Hostname2: $HOST2"
echo "BASH: `date` Type: $TYPE"
echo "BASH: `date` Repository: $DIR_REPOSIT"
echo "BASH: `date` IOS Type: $IOS_TYPE"


#case $GROUP in
#	netit)		DIR_REPOSIT="/opt/cvs/netit";;
#	nsu)		DIR_REPOSIT="/opt/cvs/nsu";;
#	infserv)	DIR_REPOSIT="/opt/cvs/infserv";;
#esac

#DIR_REPOSIT="/opt/cvs/$GROUP";

DIR_TFTP="/tftpboot"

COMM_RW="34antoN26sOi91SOiGA"
MIB_CONFIG=".1.3.6.1.4.1.9.2.1.55"

#OID_XR_CREATE=".1.3.6.1.4.1.9.9.96.1.1.1.1.14.777"
#OID_XR_SET_PROTOCOL=".1.3.6.1.4.1.9.9.96.1.1.1.1.2.777"
#OID_XR_SET_COPY=".1.3.6.1.4.1.9.9.96.1.1.1.1.3.777"
#OID_XR_SET_COPY_CONFIG=".1.3.6.1.4.1.9.9.96.1.1.1.1.4.777"
#OID_XR_SET_ADDRESS=".1.3.6.1.4.1.9.9.96.1.1.1.1.5.777"
#OID_XR_SET_DESTINATION=".1.3.6.1.4.1.9.9.96.1.1.1.1.6.777"
#OID_XR_ACTIVATE=".1.3.6.1.4.1.9.9.96.1.1.1.1.14.777"
#OID_XR_DELETE=".1.3.6.1.4.1.9.9.96.1.1.1.1.14.777"

if [ $TYPE = "cisco" ]
then
#	if [ $IOS_TYPE = "xr" ]
#	then
#		echo "BASH: `date` Creating entry for IOS XR"
#		echo "BASH: $SSET -v$SNMP_VERSION -t200 -c$COMM_RW $HOST $OID_XR_CREATE i 5"
#		`$SSET "-v$SNMP_VERSION" "-t200" "-c$COMM_RW" "$HOST" "$OID_XR_CREATE" i 5`
#		echo "BASH: $SSET -v$SNMP_VERSION -t200 -c$COMM_RW $HOST $OID_XR_SET_PROTOCOL i 1"
#		`$SSET "-v$SNMP_VERSION" "-t200" "-c$COMM_RW" "$HOST" "$OID_XR_SET_PROTOCOL" i 1`
#		echo "BASH: $SSET -v$SNMP_VERSION -t200 -c$COMM_RW $HOST $OID_XR_SET_COPY i 4"
#		`$SSET "-v$SNMP_VERSION" "-t200" "-c$COMM_RW" "$HOST" "$OID_XR_SET_COPY" i 4`
#		echo "BASH: $SSET -v$SNMP_VERSION -t200 -c$COMM_RW $HOST $OID_XR_SET_COPY_CONFIG i 1"
#		`$SSET "-v$SNMP_VERSION" "-t200" "-c$COMM_RW" "$HOST" "$OID_XR_SET_COPY_CONFIG" i 1`
#		echo "BASH: $SSET -v$SNMP_VERSION -t200 -c$COMM_RW $HOST $OID_XR_SET_ADDRESS a $MYIP"
#		`$SSET "-v$SNMP_VERSION" "-t200" "-c$COMM_RW" "$HOST" "$OID_XR_SET_ADDRESS" a "$MYIP"`
#		echo "BASH: $SSET -v$SNMP_VERSION -t200 -c$COMM_RW $HOST $OID_XR_SET_DESTINATION s cs/$HOST2"
#		`$SSET "-v$SNMP_VERSION" "-t200" "-c$COMM_RW" "$HOST" "$OID_XR_SET_DESTINATION" s "cs/$HOST2"`
#		echo "BASH: `date` Activating entry for IOS XR"
#		echo "BASH: $SSET -v$SNMP_VERSION -t200 -c$COMM_RW $HOST $OID_XR_ACTIVATE i 1"
#		`$SSET "-v$SNMP_VERSION" "-t200" "-c$COMM_RW" "$HOST" "$OID_XR_ACTIVATE" i 1`
#		echo "BASH: `date` Deleting entry for IOS XR"
#		echo "BASH: $SSET -v$SNMP_VERSION -t200 -c$COMM_RW $HOST $OID_XR_DELETE i 6"
#		`$SSET "-v$SNMP_VERSION" "-t200" "-c$COMM_RW" "$HOST" "$OID_XR_DELETE" i 6`
#		sleep 5
#	else
#		if [ $HOST2 = vinR00i ] || [ $HOST2 = sitR00i ] || [ $HOST2 = gtsR00i ]
#		then
#			echo "BASH: `date` Requesting new config: $SSET -v$SNMP_VERSION -t200 -c$COMM_RW $HOST $MIB_CONFIG.$MYEXTIP s cs/$HOST2"
#			`$SSET "-v$SNMP_VERSION" "-t200" "-c$COMM_RW" "$HOST" "$MIB_CONFIG.$MYEXTIP" "s" "cs/$HOST2"`
#		else
			echo "BASH: `date` Requesting new config: $SSET -v$SNMP_VERSION -t200 -c$COMM_RW $HOST $MIB_CONFIG.$MYIP s cs/$HOST2" \
			`$SSET "-v$SNMP_VERSION" "-t200" "-c$COMM_RW" "$HOST" "$MIB_CONFIG.$MYIP" "s" "cs/$HOST2"`
#		fi
		sleep 5
#	fi
#
fi


if [ -f "$DIR_REPOSIT/$HOST2,v" ]
then
	echo "BASH: `date` Creating new revision with RCS: $RCS -U $DIR_REPOSIT/$HOST2,v"
	`$RCS -U $DIR_REPOSIT/$HOST2,v`
	echo "BASH: `date` Creating new revision with CI: $CI -m\"$MSG\" $DIR_TFTP/cs/$HOST2 $DIR_REPOSIT/$HOST2,v"
	`$CI "-m\"$MSG\"" "$DIR_TFTP/cs/$HOST2" "$DIR_REPOSIT/$HOST2,v"`
else
	echo "BASH: `date` Creating initial revision with CI: $CI -m\"$MSG\" -t-$HOST2 $DIR_TFTP/cs/$HOST2 $DIR_REPOSIT/$HOST2,v"
	`$CI "-m\"$MSG\"" "-t-$HOST2" "$DIR_TFTP/cs/$HOST2" "$DIR_REPOSIT/$HOST2,v"`
	echo "BASH: `date` Creating initial revision with RCS: $RCS -U $DIR_REPOSIT/$HOST2,v"
	`$RCS -U $DIR_REPOSIT/$HOST2,v`
fi


echo "BASH: `date` Setting permission 0644 to CVS file: /bin/chmod 644 $DIR_REPOSIT/$HOST2,v"
`/bin/chmod 644 $DIR_REPOSIT/$HOST2,v`

