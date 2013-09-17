#!/bin/bash
# Assumptions:
#	eth0 = management and iSCSI target interface
#	eth1 = replication network, usually a direct link between nodes
#	disks: 4; os, drbd meta data, iscsi config data, and iscsi LUN

#
# check for permissions
#
if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root/sudo user"
	exit 1
fi 

#
# check number of interfaces
#
IF_COUNT=`wc -w <<<$(netstat -i | cut -d" " -f1 | egrep -v "^Kernel|Iface|lo")`
if [ "$IF_COUNT" -lt 2 ]
then
	echo "This node needs at least two network intefaces."
	exit -1
fi

#
# check number of disks
#
DISK_COUNT=`fdisk -l | grep "^Disk /dev" | wc -l`
if [ "$DISK_COUNT" -lt 4 ]
then
	echo "This node needs at least 4 disks/logical volumes."  
	exit -1
fi

#
# User Settings (TODO: read values from user)
#
DEV_DRBD=/dev/xvdb
DEV_CONFIG=/dev/xvdc
DEV_ISCSI=/dev/xvde

LOCAL_FQDN=`hostname --fqdn`
LOCAL_HOST=`hostname`
LOCAL_LAN=`ip addr show eth0 | grep "inet " | awk '{print $2}' | sed 's/\/.*//'`
LOCAL_SAN=`ip addr show eth1 | grep "inet " | awk '{print $2}' | sed 's/\/.*//'`

echo "Is this Primary or Secondary node (1/2)?"
read primary
if [ "$primary" == "1" ] 
then
	IS_PRIMARY=true
	PRIMARY_FQDN=$LOCAL_FQDN
	PRIMARY_HOST=$LOCAL_HOST
	PRIMARY_LAN=$LOCAL_LAN
	PRIMARY_SAN=$LOCAL_SAN
	
	echo "Primary Node (localhost) info:"
	echo "	$PRIMARY_FQDN"
	echo "	$PRIMARY_HOST"
	echo "	$PRIMARY_LAN"
	echo "	$PRIMARY_SAN"
	echo 

	echo "FQDN of Secondary node"
	read SECONDARY_FQDN
	SECONDARY_HOST="${SECONDARY_FQDN%%.*}"
	echo "Secondary node LAN address (managment, iscsi)"
	read SECONDARY_LAN
	echo "Secondary node SAN address (replication, heartbeat)"
	read SECONDARY_SAN
else
	echo "Secondary Node (localhost) info:"
	echo "	$PRIMARY_FQDN"
	echo "	$PRIMARY_HOST"
	echo "	$PRIMARY_LAN"
	echo "	$PRIMARY_SAN"
	echo

	IS_PRIMARY=false
	echo "FQDN of Primary node"
	read PRIMARY_FQDN
	PRIMARY_HOST="${PRIMARY_FQDN%%.*}"
	echo "Primary node LAN address (managment, iscsi)"
	read PRIMARY_LAN
	echo "Primary node SAN address (replication, heartbeat)"
	read PRIMARY_SAN

	SECONDARY_FQDN=$LOCAL_FQDN
	SECONDARY_HOST=$LOCAL_HOST
	SECONDARY_LAN=$LOCAL_LAN
	SECONDARY_SAN=$LOCAL_SAN
fi 

echo "What is the Virtual IP of the iSCSI target?"
read VIRTUAL_LAN


#
# Advanced Users Settings (don't need to modify in most situations)
#
IQN=iqn.2013-09.com.ziptrek:iscsi.target.0
PART_DRBD="$DEV_DRBD"1
PART_CONFIG="$DEV_CONFIG"1
PART_ISCSI="$DEV_ISCSI"1

#
# Partition.  
# Three paritions are required:  one for the DRBD metadata,
# one for config files, and one for the iSCSI target
#
dd if=/dev/zero of=$DEV_DRBD
dd if=/dev/zero of=$DEV_CONFIG
dd if=/dev/zero of=$DEV_ISCSI
(echo n; echo p; echo 1; echo; echo; echo w) | fdisk $DEV_DRBD
(echo n; echo p; echo 1; echo; echo; echo w) | fdisk $DEV_CONFIG
(echo n; echo p; echo 1; echo; echo; echo w) | fdisk $DEV_ISCSI

#
# Configure Hosts
#
echo "$PRIMARY_LAN\t$PRIMARY_FQDN\t${PRIMARY_HOST}" >> /etc/hosts
echo "$SECONDARY_LAN\t$SECONDARY_FQDN\t${SECONDARY_HOST}" >> /etc/hosts

#
# Install some packages
#
apt-get update
apt-get install ntp drbd8-utils heartbeat iscsitarget iscsitarget-dkms

#
# Configure DRBD
#
for file in /sbin/drbdsetup /sbin/drbdadm /sbin/drbdmeta
do
	chgrp haclient $file
	chmod o-x $file
	chmod u+s $file
done

### begin iscsi.res ###
cat > /etc/drbd.d/iscsi.res << EOL
resource iscsi.config {
        protocol C;
 
        handlers {
        pri-on-incon-degr "echo o > /proc/sysrq-trigger ; halt -f";
        pri-lost-after-sb "echo o > /proc/sysrq-trigger ; halt -f";
        local-io-error "echo o > /proc/sysrq-trigger ; halt -f";
        outdate-peer "/usr/lib/heartbeat/drbd-peer-outdater -t 5";      
        }

        startup {
        degr-wfc-timeout 120;
        }

        disk {
        on-io-error detach;
        }

        net {
        cram-hmac-alg sha1;
        shared-secret "password";
        after-sb-0pri disconnect;
        after-sb-1pri disconnect;
        after-sb-2pri disconnect;
        rr-conflict disconnect;
        }

        syncer {
        rate 100M;
        verify-alg sha1;
        al-extents 257;
        }

        on $PRIMARY_HOST {
        device  /dev/drbd0;
        disk    $PART_CONFIG;
        address $PRIMARY_SAN:7788;
        meta-disk $PART_DRBD[0];
        }

        on $SECONDARY_HOST {
        device  /dev/drbd0;
        disk    $PART_CONFIG;
        address $SECONDARY_SAN:7788;
        meta-disk $PART_DRBD[0];
        }
}

resource iscsi.target.0 {
        protocol C;
 
        handlers {
        pri-on-incon-degr "echo o > /proc/sysrq-trigger ; halt -f";
        pri-lost-after-sb "echo o > /proc/sysrq-trigger ; halt -f";
        local-io-error "echo o > /proc/sysrq-trigger ; halt -f";
        outdate-peer "/usr/lib/heartbeat/drbd-peer-outdater -t 5";      
        }

        startup {
        degr-wfc-timeout 120;
        }

        disk {
        on-io-error detach;
        }

        net {
        cram-hmac-alg sha1;
        shared-secret "password";
        after-sb-0pri disconnect;
        after-sb-1pri disconnect;
        after-sb-2pri disconnect;
        rr-conflict disconnect;
        }

        syncer {
        rate 100M;
        verify-alg sha1;
        al-extents 257;
        }

        on $PRIMARY_HOST {
        device  /dev/drbd1;
        disk    $PART_ISCSI;
        address $PRIMARY_SAN:7789;
        meta-disk $PART_DRBD[1];
        }

        on $SECONDARY_HOST {
        device  /dev/drbd1;
        disk    $PART_ISCSI;
        address $SECONDARY_SAN:7789;
        meta-disk $PART_DRBD[1];
        }
}
EOL
### end iscsi.res

#
# Initialize DRBD 
#
drbdadm create-md all
service drbd restart
if $IS_PRIMARY ; then
	drbdadm -- --overwrite-data-of-peer primary all
	mkfs.jfs /dev/drbd0
	mkdir -p /mnt/config
	mount /dev/drbd0 /mnt/config
	mkdir -p /mnt/config/iet

	### begin ietd.conf
	echo > /mnt/config/iet/ietd.conf << EOL	
	Target $IQN 
        #IncomingUser geekshlby secret
        #OutgoingUser geekshlby password
        Lun 0 Path=$PART_ISCSI,Type=blockio
        Alias disk0
        MaxConnections         1
        InitialR2T             Yes
        ImmediateData          No
        MaxRecvDataSegmentLength 8192
        MaxXmitDataSegmentLength 8192
        MaxBurstLength         262144
        FirstBurstLength       65536
        DefaultTime2Wait       2
        DefaultTime2Retain     20
        MaxOutstandingR2T      8
        DataPDUInOrder         Yes
        DataSequenceInOrder    Yes
        ErrorRecoveryLevel     0
        HeaderDigest           CRC32C,None
        DataDigest             CRC32C,None
        Wthreads               8
	EOL	
	### end ietd.conf

	echo ALL ALL > /mnt/config/iet/initiators.allow	
	echo ALL $VIRTUAL_LAN > /mnt/config/iet/targets.allow
fi

#
# Setup iscsi target
#
sed -i s/false/true/ /etc/default/iscsitarget
update-rc.d -f iscsitarget remove
mv /etc/iet /etc/iet.orig
ln -s /mnt/config/iet /etc/iet

#
# Setup heartbeat
#
mv /etc/heartbeat/ha.cf /etc/heartbeat/ha.orig
cat > /etc/heartbeat/ha.orig << EOL
	logfile /var/log/ha.log
	logfacility local0
	keepalive 2
	deadtime 30
	warntime 10
	initdead 120
	bcast eth0, eth1
	auto_failback on
	node $PRIMARY_HOST
	node $SECONDARY_HOST
EOL
cat > /etc/heartbeat/authkeys << EOL
	auth 3
	3 md5 password
EOL
chmod 600 /etc/heartbeat/authkeys
cat > /etc/heartbeat/haresources << EOL
	$PRIMARY_HOST drbddisk::iscsi.config Filesystem::/dev/drbd0::/mnt/config::jfs
	$PRIMARY_HOST IPAddr::$VIRTUAL_LAN/24/eth0 drbddisk::iscsi.target.0 iscsitarget
EOL

echo "Configure other node and/or reboot this node now"
exit 0
