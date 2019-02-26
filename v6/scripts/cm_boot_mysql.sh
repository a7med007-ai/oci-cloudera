#!/bin/bash

LOG_FILE="/var/log/cloudera-OCI-initialize.log"

# logs everything to the $LOG_FILE
log() {
  echo "$(date) [${EXECNAME}]: $*" >> "${LOG_FILE}"
}

EXECNAME="TUNING"

log "-> START"
# Disable SELinux
sed -i.bak 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
setenforce 0

## Modify resolv.conf to ensure DNS lookups work
rm -f /etc/resolv.conf
echo "search public1.cdhvcn.oraclevcn.com public2.cdhvcn.oraclevcn.com public3.cdhvcn.oraclevcn.com private1.cdhvcn.oraclevcn.com private2.cdhvcn.oraclevcn.com private3.cdhvcn.oraclevcn.com bastion1.cdhvcn.oraclevcn.com bastion2.cdhvcn.oraclevcn.com bastion3.cdhvcn.oraclevcn.com" > /etc/resolv.conf
echo "nameserver 169.254.169.254" >> /etc/resolv.conf

## Disable Transparent Huge Pages
echo never | tee -a /sys/kernel/mm/transparent_hugepage/enabled
echo "echo never | tee -a /sys/kernel/mm/transparent_hugepage/enabled" | tee -a /etc/rc.local

## Set vm.swappiness to 1
echo vm.swappiness=0 | tee -a /etc/sysctl.conf
echo 0 | tee /proc/sys/vm/swappiness

## Tune system network performance
echo net.ipv4.tcp_timestamps=0 >> /etc/sysctl.conf
echo net.ipv4.tcp_sack=1 >> /etc/sysctl.conf
echo net.core.rmem_max=4194304 >> /etc/sysctl.conf
echo net.core.wmem_max=4194304 >> /etc/sysctl.conf
echo net.core.rmem_default=4194304 >> /etc/sysctl.conf
echo net.core.wmem_default=4194304 >> /etc/sysctl.conf
echo net.core.optmem_max=4194304 >> /etc/sysctl.conf
echo net.ipv4.tcp_rmem="4096 87380 4194304" >> /etc/sysctl.conf
echo net.ipv4.tcp_wmem="4096 65536 4194304" >> /etc/sysctl.conf
echo net.ipv4.tcp_low_latency=1 >> /etc/sysctl.conf

## Tune File System options
sed -i "s/defaults        1 1/defaults,noatime        0 0/" /etc/fstab

## Set Limits
echo "hdfs  -       nofile  32768
hdfs  -       nproc   2048
hbase -       nofile  32768
hbase -       nproc   2048" >> /etc/security/limits.conf
ulimit -n 262144

systemctl stop firewalld
systemctl disable firewalld

## Enable root login via SSH key
cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.bak
cp /home/opc/.ssh/authorized_keys /root/.ssh/authorized_keys

## KERBEROS INSTALL
EXECNAME="KERBEROS"
log "-> INSTALL"

yum -y install krb5-server krb5-libs krb5-workstation
KERBEROS_PASSWORD="SOMEPASSWORD"
SCM_USER_PASSWORD="somepassword"
kdc_server=$(hostname)
kdc_fqdn=`host $kdc_server | gawk '{print $1}'`
realm="hadoop.com"
REALM="HADOOP.COM"
log "-> CONFIG"
rm -f /etc/krb5.conf
cat > /etc/krb5.conf << EOF
# Configuration snippets may be placed in this directory as well
includedir /etc/krb5.conf.d/

[libdefaults]
 default_realm = ${REALM}
 dns_lookup_realm = false
 dns_lookup_kdc = false
 rdns = false
 ticket_lifetime = 24h
 renew_lifetime = 7d  
 forwardable = true
 udp_preference_limit = 1000000
 default_tkt_enctypes = rc4-hmac 
 default_tgs_enctypes = rc4-hmac
 permitted_enctypes = rc4-hmac

[realms]
    ${REALM} = {
        kdc = ${kdc_fqdn}:88
        admin_server = ${kdc_fqdn}:749
        default_domain = ${realm}
    }

[domain_realm]
    .${realm} = ${REALM}
     ${realm} = ${REALM}

[kdc]
    profile = /var/kerberos/krb5kdc/kdc.conf

[logging]
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmin.log
    default = FILE:/var/log/krb5lib.log
EOF


rm -f /var/kerberos/krb5kdc/kdc.conf
cat > /var/kerberos/krb5kdc/kdc.conf << EOF
default_realm = ${REALM}

[kdcdefaults]
    v4_mode = nopreauth
    kdc_ports = 0

[realms]
    ${REALM} = {
        kdc_ports = 88
        admin_keytab = /var/kerberos/krb5kdc/kadm5.keytab
        database_name = /var/kerberos/krb5kdc/principal
        acl_file = /var/kerberos/krb5kdc/kadm5.acl
        key_stash_file = /var/kerberos/krb5kdc/stash
        max_life = 10h 0m 0s
        max_renewable_life = 7d 0h 0m 0s
        master_key_type = des3-hmac-sha1
        supported_enctypes = rc4-hmac:normal 
        default_principal_flags = +preauth
    }
EOF

rm -f /var/kerberos/krb5kdc/kadm5.acl
cat > /var/kerberos/krb5kdc/kadm5.acl << EOF
*/admin@${REALM}    *
cloudera-scm@${REALM}	*
EOF

kdb5_util create -r ${REALM} -s -P ${KERBEROS_PASSWORD}

echo -e "addprinc root/admin\n${KERBEROS_PASSWORD}\n${KERBEROS_PASSWORD}\naddprinc cloudera-scm\n${SCM_USER_PASSWORD}\n${SCM_USER_PASSWORD}\nktadd -k /var/kerberos/krb5kdc/kadm5.keytab kadmin/admin\nktadd -k /var/kerberos/krb5kdc/kadm5.keytab kadmin/changepw\nexit\n" | kadmin.local -r ${REALM}
log "-> START"
systemctl start krb5kdc.service
systemctl start kadmin.service
systemctl enable krb5kdc.service
systemctl enable kadmin.service

## INSTALL CLOUDERA MANAGER
EXECNAME="Cloudera Manager & Pre-Reqs Install"
log "-> Installation"
rpm --import https://archive.cloudera.com/cdh6/6.1.0/redhat7/yum//RPM-GPG-KEY-cloudera
wget http://archive.cloudera.com/cm6/6.1.0/redhat7/yum/cloudera-manager.repo -O /etc/yum.repos.d/cloudera-manager.repo
yum install oracle-j2sdk* cloudera-manager-server java-1.8.0-openjdk.x86_64 python-pip -y
pip install psycopg2==2.7.5 --ignore-installed
yum install oracle-j2sdk1.8.x86_64 cloudera-manager-daemons cloudera-manager-agent -y
cm_host=`host cdh-utility-1 | gawk '{print $1}'`
cp /etc/cloudera-scm-agent/config.ini /etc/cloudera-scm-agent/config.ini.orig
sed -e "s/\(server_host=\).*/\1${cm_host}/" -i /etc/cloudera-scm-agent/config.ini
# AUTO-TLS Enable
export JAVA_HOME=/usr/java/jdk1.8.0_141-cloudera 
/opt/cloudera/cm-agent/bin/certmanager setup --configure-services
systemctl start cloudera-scm-agent

create_random_password()
{
  perl -le 'print map { ("a".."z", "A".."Z", 0..9)[rand 62] } 1..10'
}

##
## MAIN MYSQL INSTALL
## 
EXECNAME="MySQL DB"
log "->Install"
wget http://repo.mysql.com/mysql-community-release-el7-5.noarch.rpm
rpm -ivh mysql-community-release-el7-5.noarch.rpm
yum install mysql-server -y
log "->Tuning"
head -n -6 /etc/my.cnf >> /etc/my.cnf.new
mv /etc/my.cnf /etc/my.cnf.rpminstall
mv /etc/my.cnf.new /etc/my.cnf
echo -e "transaction_isolation = READ-COMMITTED\n\
read_buffer_size = 2M\n\
read_rnd_buffer_size = 16M\n\
sort_buffer_size = 8M\n\
join_buffer_size = 8M\n\
query_cache_size = 64M\n\
query_cache_limit = 8M\n\
query_cache_type = 1\n\
thread_stack = 256K\n\
thread_cache_size = 64\n\
max_connections = 700\n\
key_buffer_size = 32M\n\
max_allowed_packet = 32M\n\
log_bin=/var/lib/mysql/mysql_binary_log\n\
server_id=1\n\
binlog_format = mixed\n\
\n\
# InnoDB Settings\n\
innodb_file_per_table = 1\n\
innodb_flush_log_at_trx_commit = 2\n\
innodb_log_buffer_size = 64M\n\
innodb_thread_concurrency = 8\n\
innodb_buffer_pool_size = 4G\n\
innodb_flush_method = O_DIRECT\n\
innodb_log_file_size = 512M\n\
\n\
[mysqld_safe]\n\
log-error=/var/log/mysqld.log
pid-file=/var/run/mysqld/mysqld.pid \n\
\n\
sql_mode=STRICT_ALL_TABLES\n\
" >> /etc/my.cnf
log "->Start"
systemctl enable mysqld
systemctl start mysqld
log "->Bootstrap Databases"
mysql -e "UPDATE mysql.user SET Password = PASSWORD('SOMEPASSWORD') WHERE User = 'root'"
mysql -e "DROP USER ''@'localhost'"
mysql -e "DROP USER ''@'$(hostname)'"
mkdir -p /etc/mysql
for DATABASE in "scm" "amon" "rman" "hue" "metastore" "sentry" "nav" "navms" "oozie"; do
	pw=$(create_random_password)
	if [ ${DATABASE} = "metastore" ]; then
		USER="hive"
	else
		USER=${DATABASE}
	fi
	echo -e "CREATE DATABASE ${DATABASE} DEFAULT CHARACTER SET utf8 DEFAULT COLLATE utf8_general_ci;" >> /etc/mysql/cloudera.sql
	echo -e "GRANT ALL ON ${DATABASE}.* TO \'${USER}\'@'%' IDENTIFIED BY \'${pw}\';" >> /etc/mysql/cloudera.sql
	echo "${USER}:${pw}" >> /etc/mysql/mysql.pw
done;
sed -i 's/\\//g' /etc/mysql/cloudera.sql
mysql -u root < /etc/mysql/cloudera.sql
mysql -e "FLUSH PRIVILEGES"
log "->Java Connector"
wget https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-5.1.46.tar.gz
tar zxvf mysql-connector-java-5.1.46.tar.gz
mkdir -p /usr/share/java/
cd mysql-connector-java-5.1.46
cp mysql-connector-java-5.1.46-bin.jar /usr/share/java/mysql-connector-java.jar	
log "->SCM Prepare DB"
for user in `cat /etc/mysql/mysql.pw | gawk -F ':' '{print $1}'`; do
	log "-->${user} preparation"
	pw=`cat /etc/mysql/mysql.pw | grep -w $user | cut -d ':' -f 2`
	if [ $user = "hive" ]; then 
		database="metastore"
	else
		database=${user}
	fi
	/opt/cloudera/cm/schema/scm_prepare_database.sh mysql ${database} ${user} ${pw}
done;
##
## END MYSQL
##
## DISK SETUP
vol_match() {
case $i in
        1) disk="oraclevdb";;
        2) disk="oraclevdc";;
        3) disk="oraclevdd";;
        4) disk="oraclevde";;
        5) disk="oraclevdf";;
        6) disk="oraclevdg";;
        7) disk="oraclevdh";;
        8) disk="oraclevdi";;
        9) disk="oraclevdj";;
        10) disk="oraclevdk";;
        11) disk="oraclevdl";;
        12) disk="oraclevdm";;
        13) disk="oraclevdn";;
        14) disk="oraclevdo";;
        15) disk="oraclevdp";;
        16) disk="oraclevdq";;
        17) disk="oraclevdr";;
        18) disk="oraclevds";;
        19) disk="oraclevdt";;
        20) disk="oraclevdu";;
        21) disk="oraclevdv";;
        22) disk="oraclevdw";;
        23) disk="oraclevdx";;
        24) disk="oraclevdy";;
        25) disk="oraclevdz";;
        26) disk="oraclevdab";;
        27) disk="oraclevdac";;
        28) disk="oraclevdad";;
        29) disk="oraclevdae";;
        30) disk="oraclevdaf";;
        31) disk="oraclevdag";;
esac
}


iscsi_setup() {
        log "-> ISCSI Volume Setup - Volume $i : IQN ${iqn[$n]}"
        iscsiadm -m node -o new -T ${iqn[$n]} -p 169.254.2.${n}:3260
        log "--> Volume ${iqn[$n]} added"
        iscsiadm -m node -o update -T ${iqn[$n]} -n node.startup -v automatic
        log "--> Volume ${iqn[$n]} startup set"
        iscsiadm -m node -T ${iqn[$n]} -p 169.254.2.${n}:3260 -l
        log "--> Volume ${iqn[$n]} done"
}

iscsi_target_only(){
        log "-->Logging into Volume ${iqn[$n]}"
        iscsiadm -m node -T ${iqn[$n]} -p 169.254.2.${n}:3260 -l
}

## Look for all ISCSI devices in sequence, finish on first failure
EXECNAME="ISCSI"
done="0"
log "-- Detecting Block Volumes --"
for i in `seq 2 33`; do
        if [ $done = "0" ]; then
                iscsiadm -m discoverydb -D -t sendtargets -p 169.254.2.${i}:3260 2>&1 2>/dev/null
                iscsi_chk=`echo -e $?`
                if [ $iscsi_chk = "0" ]; then
                        iqn[$i]=`iscsiadm -m discoverydb -D -t sendtargets -p 169.254.2.${i}:3260 | gawk '{print $2}'`
                        log "-> Discovered volume $((i-1)) - IQN: ${iqn[$i]}"
                        continue
                else
                        log "--> Discovery Complete - ${#iqn[@]} volumes found"
                        done="1"
                fi
        fi
done;
log "-- Setup for ${#iqn[@]} Block Volumes --"
if [ ${#iqn[@]} -gt 0 ]; then 
	for i in `seq 1 ${#iqn[@]}`; do
		n=$((i+1))
		iscsi_setup
	done;
fi

EXECNAME="DISK PROVISIONING"
#
# Disk Setup uses drives /dev/sdb and /dev/sdc for statically mapped Cloudera partitions (logs, parcels)
# If customizing your Terraform Templates - be sure to pay attention here to ensure proper mounts are presented
#
## Primary Disk Mounting Function
data_mount () {
  log "-->Mounting /dev/$disk to /data$dcount"
  mkdir -p /data$dcount
  mount -o noatime,barrier=1 -t ext4 /dev/$disk /data$dcount
  UUID=`lsblk -no UUID /dev/$disk`
  echo "UUID=$UUID   /data$dcount    ext4   defaults,noatime,discard,barrier=0 0 1" | tee -a /etc/fstab
}

block_data_mount () {
  log "-->Mounting /dev/oracleoci/$disk to /data$dcount"
  mkdir -p /data$dcount
  mount -o noatime,barrier=1 -t ext4 /dev/oracleoci/$disk /data$dcount
  UUID=`lsblk -no UUID /dev/oracleoci/$disk`
  echo "UUID=$UUID   /data$dcount    ext4   defaults,_netdev,nofail,noatime,discard,barrier=0 0 2" | tee -a /etc/fstab
}

## Check for x>0 devices
log "->Checking for disks..."
nvcount="0"
bvcount="0"
## Execute - will format all devices except sda for use as data disks in HDFS
dcount=0
for disk in `cat /proc/partitions | grep nv`; do
        log "-->Processing /dev/$disk"
        mke2fs -F -t ext4 -b 4096 -E lazy_itable_init=1 -O sparse_super,dir_index,extent,has_journal,uninit_bg -m1 /dev/$disk
        data_mount
        dcount=$((dcount+1))
done;
if [ ${#iqn[@]} -gt 0 ]; then
for i in `seq 1 ${#iqn[@]}`; do
	n=$((i+1))
        dsetup="0"
        while [ $dsetup = "0" ]; do
                vol_match
                log "-->Checking /dev/oracleoci/$disk"
                if [ -h /dev/oracleoci/$disk ]; then
                        mke2fs -F -t ext4 -b 4096 -E lazy_itable_init=1 -O sparse_super,dir_index,extent,has_journal,uninit_bg -m1 /dev/oracleoci/$disk
                        if [ $disk = "oraclevdb" ]; then
                                log "--->Mounting /dev/oracleoci/$disk to /var/log/cloudera"
                                mkdir -p /var/log/cloudera
                                mount -o noatime,barrier=1 -t ext4 /dev/oracleoci/$disk /var/log/cloudera
                                UUID=`lsblk -no UUID /dev/oracleoci/$disk`
                                echo "UUID=$UUID   /var/log/cloudera    ext4   defaults,_netdev,nofail,noatime,discard,barrier=0 0 2" | tee -a /etc/fstab
                        elif [ $disk = "oraclevdc" ]; then
                                log "--->Mounting /dev/oracleoci/$disk to /opt/cloudera"
				if [ -d /opt/cloudera ]; then
		                        mv /opt/cloudera /opt/cloudera_pre
                		        mkdir -p /opt/cloudera
		                        mount -o noatime,barrier=1 -t ext4 /dev/oracleoci/$disk /opt/cloudera
		                        mv /opt/cloudera_pre/* /opt/cloudera
                		        rm -fR /opt/cloudera_pre
		                else
                		        mkdir -p /opt/cloudera
		                        mount -o noatime,barrier=1 -t ext4 /dev/oracleoci/$disk /opt/cloudera
		                fi
                                UUID=`lsblk -no UUID /dev/oracleoci/$disk`
                                echo "UUID=$UUID   /opt/cloudera    ext4   defaults,_netdev,nofail,noatime,discard,barrier=0 0 2" | tee -a /etc/fstab
                        else
                                block_data_mount
                                dcount=$((dcount+1))
                        fi
                        /sbin/tune2fs -i0 -c0 /dev/oracleoci/$disk
                        dsetup="1"
                else
                        log "--->${disk} not found, running ISCSI setup again."
                        iscsi_target_only
                        sleep 5
                fi
        done;
done;
fi
## START CLOUDERA MANAGER
log "------- Starting Cloudera Manager -------"
chown -R cloudera-scm:cloudera-scm /etc/cloudera-scm-server
#chown -R cloudera-scm:cloudera-scm /opt/cloudera
#chown -R cloudera-scm:cloudera-scm /var/log/cloudera
systemctl start cloudera-scm-server

EXECNAME="END"
log "->DONE"
