#!/bin/bash
################################################################################
######################## Microway Cluster Management Software (MCMS) for OpenHPC
################################################################################
#
# Copyright (c) 2015-2016 by Microway, Inc.
#
# This file is part of Microway Cluster Management Software (MCMS) for OpenHPC.
#
#    MCMS for OpenHPC is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    MCMS for OpenHPC is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with MCMS.  If not, see <http://www.gnu.org/licenses/>
#
################################################################################



################################################################################
##
## This script is a recipe for setting up OpenHPC on CentOS 7.x Linux
##
## http://www.openhpc.community/
##
##
## This script should be run on the cluster's Head/Master Node - also referred
## to as the System Management Server (SMS). This script presumes that a Red Hat
## derivative (CentOS, SL, etc) has just been installed (with vanilla
## configuration). It builds a ready-to-run compute node image with optional
## support for InfiniBand, NVIDIA GPUs and Xeon Phi coprocessors.
##
##
## Please note that certain design/configuration choices are made by this script
## which may not be compatible with all sites. Efforts are made to maintain
## portability, but compatibility cannot be guaranteed.
##
################################################################################



################################################################################
# Determine where this script is running from (so we can locate patches, etc.)
################################################################################
install_script_dir="$( dirname "$( readlink -f "$0" )" )"

dependencies_dir=${install_script_dir}/dependencies
config_file=${install_script_dir}/configuration_settings.txt


# Ensure the settings have been completed
if [[ ! -r ${config_file} ]]; then
    echo "

    This script requires you to provide configuration settings. Please ensure
    that the file ${config_file} exists and has been fully completed.
    "
    exit 1
else
    source ${config_file}
fi

if [[ ! -z "$(egrep "^[^#].*ChangeMe" ${config_file})" ]]; then
    echo "

    For security, you *must* change the passwords in the configuration file.
    Please double-check your settings in ${config_file}
    "
    exit 1
fi



################################################################################
# Currently, only RHEL/SL/CentOS 7 is supported for the bootstrap
################################################################################
distribution=$(egrep "CentOS Linux 7|Scientific Linux 7|Red Hat Enterprise Linux Server release 7" /etc/*-release)
centos_check=$?

if [[ ${centos_check} -ne 0 ]]; then
    echo "

    Currently, only RHEL, Scientific and CentOS Linux 7 are supported
    "
    exit 1
else
    echo "RHEL/SL/CentOS 7 was detected. Continuing..."
fi



################################################################################
# Update system packages and EPEL package repo
################################################################################
yum -y update
yum -y install epel-release



################################################################################
# Install tools we'll need during the setup
################################################################################
yum -y install python-pip


################################################################################
# If enabled, disable auto-update on the Head Node.
# The compute nodes don't have yum installed.
################################################################################
if [[ -r /etc/sysconfig/yum-autoupdate ]]; then
    sed -i 's/ENABLED="true"/ENABLED="false"/' /etc/sysconfig/yum-autoupdate
fi



################################################################################
# Disable SELinux
################################################################################
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config



################################################################################
# Enable NTP (particularly important for things like SLURM and Ceph)
################################################################################
yum -y install ntp ntpdate ntp-doc

if [[ ! -z "${ntp_server}" ]]; then
    sed -i 's/^server /#server /' /etc/ntp.conf
    echo -e "

server ${ntp_server}

" >>  /etc/ntp.conf

    ntpdate ${ntp_server}
else
    ntpdate 0.rhel.pool.ntp.org \
            1.rhel.pool.ntp.org \
            2.rhel.pool.ntp.org \
            3.rhel.pool.ntp.org
fi

# Because some clusters are not connected to the Internet, we need to enable
# orphan mode as described here:
#
#   https://www.eecis.udel.edu/~mills/ntp/html/miscopt.html#tos
#
echo "

tos orphan 5

" >>  /etc/ntp.conf
hwclock --systohc --utc
systemctl enable ntpd.service
systemctl start ntpd.service



################################################################################
# Disable X-Windows since the Head Node is typically a headless server
################################################################################
systemctl set-default multi-user.target



################################################################################
# Add the OpenHPC repository and install the baseline OpenHPC packages
################################################################################
curl -L -o /tmp/ohpc-release.x86_64.rpm ${ohpc_repo}
rpm -i /tmp/ohpc-release.x86_64.rpm
rm -f /tmp/ohpc-release.x86_64.rpm

yum -y install docs-ohpc
yum -y groupinstall ohpc-base
yum -y groupinstall ohpc-warewulf
yum -y install warewulf-ipmi-ohpc

# Create a group for HPC administrators
groupadd hpc-admin



################################################################################
# Install Genders (which associates roles with each system)
################################################################################
yum -y install genders-ohpc
install -p -o root -g root -m 644 ${dependencies_dir}/etc/genders /etc/genders

# Set up the default roles for the Head/SMS and Compute Node systems
echo -e "${sms_name}\thead,sms,login" >> /etc/genders

for ((i=0; i<$compute_node_count; i++)) ; do
    c_name=${compute_node_name_prefix}$(( ${i} + 1 ))
    echo -e "${c_name}\tcompute,bmc=${c_bmc[$i]}"
done >> /etc/genders



################################################################################
# Install ClusterShell (Python-based library for parallel command execution)
################################################################################
yum -y install clustershell-ohpc

# Set up node definitions
mv /etc/clustershell/groups.d/{local.cfg,local.cfg.orig}
echo "
adm: ${sms_name}
compute: ${compute_node_name_prefix}[1-${compute_node_count}]
all: @adm,@compute

" > /etc/clustershell/groups.d/local.cfg



################################################################################
# Add InfiniBand support
################################################################################
if [[ "${enable_infiniband}" == "true" ]]; then
    yum -y groupinstall "InfiniBand Support"
    yum -y install infiniband-diags perftest qperf opensm

    echo "
# Allow user processes to pin more memory (required for InfiniBand/RDMA)
*       soft    memlock         unlimited
*       hard    memlock         unlimited
" > /etc/security/limits.d/rdma.conf

    echo "

DEVICE=ib0
BOOTPROTO=static
IPADDR=${sms_ipoib}
NETMASK=${ipoib_netmask}
ONBOOT=yes
STARTMODE='auto'

" >> /etc/sysconfig/network-scripts/ifcfg-ib0

    systemctl enable rdma.service
    systemctl start rdma.service

    systemctl enable opensm.service
    systemctl start opensm.service
fi



################################################################################
# Configure the Head Node to be able to talk to Compute Node BMCs
# This assumes that the Compute Node BMCs are using their shared network port.
################################################################################
network_alias_file="/etc/sysconfig/network-scripts/ifcfg-${sms_eth_internal}:0"
cp /etc/sysconfig/network-scripts/ifcfg-${sms_eth_internal} ${network_alias_file}
sed -i "s/NM_CONTROLLED.*/NM_CONTROLLED=no/" ${network_alias_file}
sed -i "s/DEVICE.*/DEVICE=${sms_eth_internal}:0/" ${network_alias_file}
sed -i "s/${internal_subnet_prefix}/${bmc_subnet_prefix}/" ${network_alias_file}
sed -i "s/NETMASK.*/NETMASK=${bmc_netmask}/" ${network_alias_file}



################################################################################
# Configure the firewall
################################################################################
# Ensure the firewall is active (some VM images don't include it)
yum -y install firewalld
systemctl enable firewalld.service
systemctl start firewalld.service

# Allow all traffic on the internal cluster network interface
firewall-cmd --permanent --zone=trusted --change-interface=${sms_eth_internal}

# Perform NAT for traffic going out the public interface
firewall-cmd --permanent --zone=public --add-masquerade
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/ip_forward.conf

# Be restrictive on the external network interface
firewall-cmd --permanent --zone=public --change-interface=${sms_eth_external}

# If there is an InfiniBand fabric, trust its traffic
if [[ "${enable_infiniband}" == "true" ]]; then
    firewall-cmd --permanent --zone=trusted --change-interface=ib0
fi

# Reload rules for them to take effect
firewall-cmd --reload



################################################################################
# Configure and start the Warewulf services
################################################################################

sed -i "s/device = eth1/device = ${sms_eth_internal}/" /etc/warewulf/provision.conf


# Apache
export HTTPD_FILE=/etc/httpd/conf.d/warewulf-httpd.conf
sed -i -r "s/cgi-bin>\$/cgi-bin>\n    Require all granted/" $HTTPD_FILE
sed -i "s/Allow from all/Require all granted/" $HTTPD_FILE
perl -ni -e "print unless /^\s+Order allow,deny/" $HTTPD_FILE

systemctl enable httpd.service
systemctl restart httpd.service


# TFTP
sed -i -r "s/^\s+disable\s+= yes/       disable = no/" /etc/xinetd.d/tftp
systemctl restart xinetd.service


# MariaDB Database
systemctl enable mariadb.service
systemctl restart mariadb.service


# NFS Exports
echo "

/home         *(rw,no_subtree_check,fsid=10,no_root_squash)
/opt          *(ro,no_subtree_check,fsid=11)

" >> /etc/exports
exportfs -a

# Enable the NFS services
systemctl enable rpcbind.service
systemctl enable nfs-server.service

# The following fixes may be needed:
#
# echo "
# [Install]
# WantedBy=multi-user.target
#
# " >> /usr/lib/systemd/system/nfs-idmap.service
# echo "
#
# [Install]
# WantedBy=nfs.target
#
# " >> /usr/lib/systemd/system/nfs-lock.service

systemctl enable nfs-lock.service
systemctl enable nfs-idmap.service
systemctl start rpcbind.service
systemctl start nfs-server.service
systemctl start nfs-lock.service
systemctl start nfs-idmap.service
systemctl restart nfs.service



################################################################################
# Set up Warewulf access to the SQL database
################################################################################
mysqladmin create warewulf
sed -i "s/database driver.*/database driver = mariadb/" /etc/warewulf/database.conf
sed -i "s/database user.*/database user = warewulf/" /etc/warewulf/database-root.conf
sed -i "s/database password.*/database password = ${db_mgmt_password}/" /etc/warewulf/database-root.conf
echo "GRANT ALL ON warewulf.* TO 'warewulf'@'localhost' IDENTIFIED BY '${db_mgmt_password}';" \
     "GRANT ALL ON warewulf.* TO 'warewulf'@'$(hostname)' IDENTIFIED BY '${db_mgmt_password}';" \
     "GRANT ALL ON warewulf.* TO 'warewulf'@'$(hostname -s)' IDENTIFIED BY '${db_mgmt_password}';" \
     "FLUSH PRIVILEGES;" \
     | mysql -u root



################################################################################
# Create the Compute Node image with OpenHPC in Warewulf
################################################################################

# Initialize the compute node chroot installation
export node_chroot_name=centos-7
export node_chroot=/opt/ohpc/admin/images/${node_chroot_name}
if [[ ! -z "${BOS_MIRROR}" ]]; then
    sed -i -r "s#^YUM_MIRROR=(\S+)#YUM_MIRROR=${BOS_MIRROR}#" /usr/libexec/warewulf/wwmkchroot/centos-7.tmpl
fi
wwmkchroot ${node_chroot_name} ${node_chroot}


# Distribute root's SSH keys across the cluster
wwinit ssh_keys
cat ~/.ssh/cluster.pub >> ${node_chroot}/root/.ssh/authorized_keys


# Revoke SSH access to all compute nodes (except for root and admins)
if [[ "${restrict_user_ssh_logins}" == "true" ]]; then
    yum -y --installroot=${node_chroot} install slurm-pam_slurm-ohpc
    echo "
- : ALL EXCEPT root hpc-admin : ALL
"   >> ${node_chroot}/etc/security/access.conf
    echo "
# Reject users who do not have jobs running on this node
account    required     pam_slurm.so
"   >> ${node_chroot}/etc/pam.d/sshd
fi


# Copy DNS resolution settings to the node installation
cp -p /etc/resolv.conf ${node_chroot}/etc/resolv.conf


# Install necessary compute node daemons
yum -y --installroot=${node_chroot} groupinstall ohpc-slurm-client
yum -y --installroot=${node_chroot} install kernel lmod-ohpc ntp

chroot ${node_chroot} systemctl enable munge.service
chroot ${node_chroot} systemctl enable slurm.service


if [[ "${enable_infiniband}" == "true" ]]; then
    yum -y --installroot=${node_chroot} groupinstall "InfiniBand Support"
    echo "
# Allow user processes to pin more memory (required for InfiniBand/RDMA)
*       soft    memlock         unlimited
*       hard    memlock         unlimited
" > ${node_chroot}/etc/security/limits.d/rdma.conf

    chroot ${node_chroot} systemctl enable rdma.service
fi


# Configure NTP
if [[ ! -z "${ntp_server}" ]]; then
    sed -i 's/^server /#server /' ${node_chroot}/etc/ntp.conf
    echo -e "

server ${ntp_server}

" >> ${node_chroot}/etc/ntp.conf
fi

echo "

# Because some clusters are not connected to the Internet, we need to enable
# orphan mode as described here:
#
#   https://www.eecis.udel.edu/~mills/ntp/html/miscopt.html#tos
#
tos orphan 5

" >> ${node_chroot}/etc/ntp.conf

chroot ${node_chroot} systemctl enable ntpd.service


# NFS mounts
echo "

# NFS mounts from the Head Node
${sms_ip}:/home         /home         nfs nfsvers=3,rsize=1024,wsize=1024,cto 0 0
${sms_ip}:/opt/ohpc/pub /opt/ohpc/pub nfs nfsvers=3 0 0
${sms_ip}:/opt/ohpc/admin/images/${node_chroot} /vnfs nfs nfsvers=3 0 0
" >> ${node_chroot}/etc/fstab



################################################################################
# Add to the stub for the /etc/hosts file
################################################################################
echo "


################################################################################
#
# WARNING: the values below were configured and set for your cluster. Changing
# these values after the fact can break the cluster - take care.
#
# Specific examples of changes which *will* break your cluster:
#
#   * changing the name of any server listed in this file
#   * more than one line for any particular host name (e.g., head)
#   * more than one line for any one IP address (e.g., 127.0.0.1)
#
#
# Also take note that the cluster will automatically add additional entries as
# you add more compute nodes. In most cases, you do not need to edit this file.
#
################################################################################

" >> /etc/hosts

# Ensure that the Head Node's name is in /etc/hosts
egrep "^[^#]+$(hostname -s)" /etc/hosts
if [[ $? -ne 0 ]]; then
    echo "

# Head Node of the cluster
${sms_ip}        $(hostname -s) salt


" >> /etc/hosts
fi



################################################################################
# Install SaltStack, which provides distribution-agnostic configuration mgmt
################################################################################
yum -y install salt-minion salt-master
yum -y --installroot=${node_chroot} install salt-minion
systemctl enable salt-master
systemctl start salt-master
systemctl enable salt-minion
systemctl start salt-minion
chroot ${node_chroot} systemctl enable salt-minion
# Note that the minion keys will need to be accepted once the cluster is up:
#   salt-key --accept-all



################################################################################
# Install SLURM
################################################################################
yum -y groupinstall ohpc-slurm-server

# Create a SLURM user and group (SLURM will run as this user)
useradd --system slurm --home-dir /var/spool/slurmd --no-create-home
# SLURM needs to be able to control nodes (e.g., power on/off)
usermod --append --groups warewulf slurm

# After installing SLURM, the configuration is vanilla. You can customize here:
#
#   http://slurm.schedmd.com/configurator.html
#
install -p -o slurm -g slurm -m 644 ${dependencies_dir}/etc/slurm/slurm.conf /etc/slurm/slurm.conf
install -p -o slurm -g slurm -m 640 ${dependencies_dir}/etc/slurm/slurmdbd.conf /etc/slurm/slurmdbd.conf

# Customize the configuration files
sed -i "s/{clusterName}/${cluster_acct_hierarchy['cluster_name']}/" /etc/slurm/slurm.conf
sed -i "s/{headName}/$(hostname -s)/" /etc/slurm/slurm.conf
sed -i "s/StoragePass={ChangeMe}/StoragePass=${db_mgmt_password}/" /etc/slurm/slurmdbd.conf

# Setup cgroups
rm -f /etc/slurm/cgroup/*
cp -a /etc/slurm/cgroup.release_common.example /etc/slurm/cgroup/release_common
# The 'blkio' and 'cpuacct' subsystems are left out as they are only needed for
# the 'jobacct_gather/cgroup' job accounting statistics plugin. The cgroup
# plugin is reported to be slower than the 'jobacct_gather/linux' plugin.
for resource in cpuset freezer memory devices; do
    ln -s /etc/slurm/cgroup/release_common /etc/slurm/cgroup/release_${resource}
done
cp -af /etc/slurm/cgroup ${node_chroot}/etc/slurm/
cp ${dependencies_dir}/etc/slurm/cgroup.conf /etc/slurm/
cp ${dependencies_dir}/etc/slurm/cgroup.conf ${node_chroot}/etc/slurm/
cp ${dependencies_dir}/etc/slurm/cgroup_allowed_devices_file.conf /etc/slurm/
cp ${dependencies_dir}/etc/slurm/cgroup_allowed_devices_file.conf ${node_chroot}/etc/slurm/

# Setup the plugin stack
cp ${dependencies_dir}/etc/slurm/plugstack.conf /etc/slurm/
cp ${dependencies_dir}/etc/slurm/plugstack.conf ${node_chroot}/etc/slurm/
mkdir -p /etc/slurm/plugstack.conf.d
cp ${dependencies_dir}/etc/slurm/plugstack.conf.d/x11.conf /etc/slurm/plugstack.conf.d/
cp -af /etc/slurm/plugstack.conf.d ${node_chroot}/etc/slurm/

# Put the prolog/epilog/healthcheck scripts in place
mkdir -p {,${node_chroot}}/etc/slurm/scripts
cp -a ${dependencies_dir}/etc/slurm/scripts/* /etc/slurm/scripts/
cp -a ${dependencies_dir}/etc/slurm/scripts/* ${node_chroot}/etc/slurm/scripts/
# Remove the simpler epilog script that comes with the distro
rm -f {,${node_chroot}}/etc/slurm/slurm.epilog.clean

# Set up SLURM log rotation
cp ${dependencies_dir}/etc/logrotate.d/slurm /etc/logrotate.d/
cp ${dependencies_dir}/etc/logrotate.d/slurm ${node_chroot}/etc/logrotate.d/

# Ensure the proper SLURM running state and log directories are in place
mkdir -p {,${node_chroot}}/var/{lib,run,spool}/slurmd
mkdir -p {,${node_chroot}}/var/log/slurm
chown slurm:slurm {,${node_chroot}}/var/{lib,run,spool}/slurmd
chown slurm:slurm {,${node_chroot}}/var/log/slurm

# Add some additional settings/capabilities during slurmd start-up
cp ${dependencies_dir}/etc/sysconfig/slurm /etc/sysconfig/
cp ${dependencies_dir}/etc/sysconfig/slurm ${node_chroot}/etc/sysconfig/
cp ${dependencies_dir}/etc/slurm/gres.conf /etc/slurm/
cp ${dependencies_dir}/etc/slurm/gres.conf ${node_chroot}/etc/slurm/

# Generate SSH key which allows slurm to spawn health checks on nodes
mkdir -p /var/spool/slurmd/.ssh/
chmod 700 /var/spool/slurmd/.ssh/
chown slurm:slurm /var/spool/slurmd/.ssh/
ssh-keygen -t rsa -N "" -f ${node_chroot}/root/.ssh/healthcheck-ssh-key   \
           -C "Allow SLURM to spawn health checks as root user on compute nodes"
mv ${node_chroot}/root/.ssh/healthcheck-ssh-key   \
   /var/spool/slurmd/.ssh/.healthcheck-ssh-key
cp -a ${node_chroot}/root/.ssh/healthcheck-ssh-key.pub   \
      /var/spool/slurmd/.ssh/.healthcheck-ssh-key.pub
chmod 600 /var/spool/slurmd/.ssh/.healthcheck-ssh-key
chown slurm:slurm /var/spool/slurmd/.ssh/.healthcheck-ssh-key   \
                  /var/spool/slurmd/.ssh/.healthcheck-ssh-key.pub
# Modify the access key to only allow the execution of the health check
cat ${node_chroot}/root/.ssh/healthcheck-ssh-key.pub | sed 's+^+no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,command="/root/.ssh/validate-ssh-command" +' >> ${node_chroot}/root/.ssh/authorized_keys
# Generate SSH key which allows slurm to power down idle nodes
ssh-keygen -t rsa -N "" -f ${node_chroot}/root/.ssh/poweroff-ssh-key   \
           -C "Allow SLURM to power off compute nodes as the root user"
mv ${node_chroot}/root/.ssh/poweroff-ssh-key   \
   /var/spool/slurmd/.ssh/.poweroff-ssh-key
cp -a ${node_chroot}/root/.ssh/poweroff-ssh-key.pub   \
      /var/spool/slurmd/.ssh/.poweroff-ssh-key.pub
chmod 600 /var/spool/slurmd/.ssh/.poweroff-ssh-key
chown slurm:slurm /var/spool/slurmd/.ssh/.poweroff-ssh-key   \
                  /var/spool/slurmd/.ssh/.poweroff-ssh-key.pub
# Modify the access key to only allow the execution of the power off on compute nodes
cat ${node_chroot}/root/.ssh/poweroff-ssh-key.pub | sed 's+^+no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,command="/root/.ssh/validate-ssh-command" +' >> ${node_chroot}/root/.ssh/authorized_keys
# Finalize SLURM's SSH key setup
cp -a ${dependencies_dir}/var/spool/slurmd/validate-ssh-command   \
      ${node_chroot}/root/.ssh/validate-ssh-command
chmod 600 ${node_chroot}/root/.ssh/authorized_keys

# Set up SQL database for slurmdbd accounting
mysqladmin create slurm_acct_db
echo "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost' IDENTIFIED BY '${db_mgmt_password}';" \
     "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'$(hostname)' IDENTIFIED BY '${db_mgmt_password}';" \
     "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'$(hostname -s)' IDENTIFIED BY '${db_mgmt_password}';" \
     "FLUSH PRIVILEGES;" \
     | mysql -u root

# Start up the SLURM services on the Head Node
systemctl enable munge.service
systemctl start munge.service
systemctl enable slurmdbd.service
systemctl start slurmdbd.service

# Set up SLURM accounting information. You must define clusters before you add
# accounts, and you must add accounts before you can add users.
sacctmgr --immediate add cluster ${cluster_acct_hierarchy['cluster_name']}
sacctmgr --immediate add account ${cluster_acct_hierarchy['default_organization']} \
    description="${cluster_acct_hierarchy['default_organization_description']}"
sacctmgr --immediate add account ${cluster_acct_hierarchy['default_account']} \
    description="${cluster_acct_hierarchy['default_account_description']}" \
    organization=${cluster_acct_hierarchy['default_organization']}

systemctl enable slurm.service
systemctl start slurm.service



################################################################################
# Secure the SQL database
################################################################################
echo "
y
${db_root_password}
${db_root_password}
y
y
y
y
" | mysql_secure_installation



################################################################################
# Ensure the PCI devices IDs are up to date
################################################################################
update-pciids
chroot ${node_chroot} update-pciids



################################################################################
# Syncronize the built-in users between Head and Compute Nodes
#
# If not done now, the users created by the following packages will have
# different UIDs and GIDs on the Compute Nodes than on the Head Node.
################################################################################
cp -af /etc/passwd ${node_chroot}/etc/
cp -af /etc/group ${node_chroot}/etc/



################################################################################
# Install Ganglia on the Head Node and Compute Nodes
################################################################################
yum -y groupinstall ohpc-ganglia
yum -y --installroot=${node_chroot} install ganglia-gmond-ohpc

systemctl enable gmond.service
systemctl enable gmetad.service

systemctl start gmond.service
systemctl start gmetad.service

chroot ${node_chroot} systemctl enable gmond.service

for i in httpd apache2; do
    if [ -d /etc/$i ]; then
        sed -i "s/Require local/Require all granted/" /etc/$i/conf.d/ganglia-ohpc.conf
    fi
done

systemctl try-restart httpd.service



################################################################################
# Install Elasticsearch for analytics on log/event data
################################################################################
rpm --import https://packages.elastic.co/GPG-KEY-elasticsearch
echo "[elasticsearch-2.x]
name=Elasticsearch repository for 2.x packages
baseurl=https://packages.elastic.co/elasticsearch/2.x/centos
gpgcheck=1
gpgkey=https://packages.elastic.co/GPG-KEY-elasticsearch
enabled=1" > /etc/yum.repos.d/elasticsearch.repo

yum -y install elasticsearch
# For security, limit connections to localhost
sed -i 's/# network.host.*/network.host: localhost/' /etc/elasticsearch/elasticsearch.yml
systemctl enable elasticsearch.service
systemctl start elasticsearch.service



################################################################################
# Install Kibana web interface to Elasticsearch
################################################################################
echo "[kibana-4.5]
name=Kibana repository for 4.5.x packages
baseurl=http://packages.elastic.co/kibana/4.5/centos
gpgcheck=1
gpgkey=http://packages.elastic.co/GPG-KEY-elasticsearch
enabled=1" > /etc/yum.repos.d/kibana.repo

yum -y install kibana
systemctl enable kibana.service
systemctl start kibana.service



################################################################################
# Install LogStash for aggregation and parsing of cluster syslogs
################################################################################
echo "[logstash-2.3]
name=Logstash repository for 2.3.x packages
baseurl=https://packages.elastic.co/logstash/2.3/centos
gpgcheck=1
gpgkey=https://packages.elastic.co/GPG-KEY-elasticsearch
enabled=1" > /etc/yum.repos.d/logstash.repo

yum -y install logstash

# Security certs are needed when transferring logs between systems
perl -0777 -pe "s/\[ v3_ca \]\n/[ v3_ca ]\n\nsubjectAltName = IP:${sms_ip}\n/" /etc/pki/tls/openssl.cnf
openssl req -config /etc/pki/tls/openssl.cnf                    \
        -x509 -days 3650 -batch -nodes -newkey rsa:2048         \
        -keyout /etc/pki/tls/private/logstash-forwarder.key     \
        -out /etc/pki/tls/certs/logstash-forwarder.crt
cp -a /etc/pki/tls/certs/logstash-forwarder.crt ${node_chroot}/etc/pki/tls/certs/

# Put the LogStash input and parsing configurations into place
cp -a ${dependencies_dir}/etc/logstash/conf.d/* /etc/logstash/conf.d/

# Put the IP-to-geolocation database into place
wget --tries=20 --waitretry=10 --retry-connrefused --output-document=-        \
     http://geolite.maxmind.com/download/geoip/database/GeoLiteCity.dat.gz |  \
     gunzip > /etc/logstash/GeoLiteCity.dat

systemctl enable logstash.service
systemctl start logstash.service



################################################################################
# Install FileBeat on Head Node and Compute Node (forwards syslogs to LogStash)
################################################################################
echo "[beats]
name=Elastic Beats Repository
baseurl=https://packages.elastic.co/beats/yum/el/\$basearch
enabled=1
gpgkey=https://packages.elastic.co/GPG-KEY-elasticsearch
gpgcheck=1" > /etc/yum.repos.d/elastic-beats.repo
cp -a /etc/yum.repos.d/elastic-beats.repo ${node_chroot}/etc/yum.repos.d/

yum -y install filebeat
yum -y --installroot=${node_chroot} install filebeat

# Put the FileBeat configuration into place
mv /etc/filebeat/filebeat.yml{,.orig}
mv ${node_chroot}/etc/filebeat/filebeat.yml{,.orig}
cp -a ${dependencies_dir}/etc/filebeat/filebeat.yml /etc/filebeat/
cp -a ${dependencies_dir}/etc/filebeat/filebeat.yml ${node_chroot}/etc/filebeat/
sed -i "s/{sms_ip}/${sms_ip}/" /etc/filebeat/filebeat.yml
sed -i "s/{sms_ip}/${sms_ip}/" ${node_chroot}/etc/filebeat/filebeat.yml

systemctl enable filebeat.service
systemctl start filebeat.service
chroot ${node_chroot} systemctl enable filebeat.service



################################################################################
# Install Intel Cluster Checker on the Head Node and Compute Nodes
################################################################################
yum -y install intel-clck-ohpc
yum -y --installroot=${node_chroot} install intel-clck-ohpc



################################################################################
# If desired, configure the Lustre parallel filesystem mount
################################################################################
if [ "${enable_lustre_client}" == "true" ];then
    # Install Lustre client on master
    yum -y install lustre-client-ohpc lustre-client-ohpc-modules

    # Enable lustre in Compute Node image
    yum -y --installroot=${node_chroot} install lustre-client-ohpc lustre-client-ohpc-modules

    mkdir -p /mnt/lustre
    mkdir -p ${node_chroot}/mnt/lustre
    echo "

${mgs_fs_name} /mnt/lustre lustre defaults,_netdev,localflock 0 0
" >> /etc/fstab
    echo "

${mgs_fs_name} /mnt/lustre lustre defaults,_netdev,localflock 0 0
" >> ${node_chroot}/etc/fstab

    # Enable o2ib for Lustre
    echo "options lnet networks=o2ib(ib0)" >> /etc/modprobe.d/lustre.conf
    echo "options lnet networks=o2ib(ib0)" >> ${node_chroot}/etc/modprobe.d/lustre.conf

    # Mount Lustre client on master
    mount /mnt/lustre
fi



################################################################################
# Finish assembly of the basic Compute Node image
################################################################################

# Configure the nodes to use the provisioning interface for the gateway
echo "GATEWAYDEV=${eth_provision}" >> ${node_chroot}/etc/sysconfig/network

# Add XFS if it isn't there
sed -i 's/ext3, ext4$/ext2, ext3, ext4, xfs/' /etc/warewulf/bootstrap.conf

# Avoid confusion on the Mellanox driver options
sed -i 's/^# modprobe += mlx4_core .*//' /etc/warewulf/bootstrap.conf

# Add fix for Mellanox module settings and drivers which might be needed
echo "

# According to OpenMPI devs, Mellanox recommends that log_mtts_per_seg be set
# low (~1) and log_num_mtt be set high (24~27). A value of 24 allows for a 256GB
# virtual address space. A value of 27 provides 1024GB. Virtual space should be
# twice that of physical memory.
modprobe += mlx4_core log_num_mtt=25 log_mtts_per_seg=1, ib_srp

# Required to load Lustre client
drivers += updates/kernel/
" >> /etc/warewulf/bootstrap.conf

if [[ "${enable_phi_coprocessor}" == "true" ]]; then
    echo "

# Driver and bridging capability for Intel(R) Xeon Phi(tm) coprocessors
drivers += extra/mic.ko
drivers += bridge
" >> /etc/warewulf/bootstrap.conf
fi

if [[ "${enable_nvidia_gpu}" == "true" ]]; then
    echo "

# Required for NVIDIA GPUs
drivers += extra/nvidia.ko
drivers += extra/nvidia-uvm.ko
" >> /etc/warewulf/bootstrap.conf
fi


# Update the bootstrap image for the current Linux kernel version
wwbootstrap `uname -r`


# Link the files which will be automatically synced to the nodes periodically
wwsh file import /etc/passwd
wwsh file import /etc/group
wwsh file import /etc/shadow
wwsh file import /etc/genders
wwsh file import /etc/slurm/slurm.conf
wwsh file import /etc/munge/munge.key

if [ "${enable_infiniband}" == "true" ];then
    wwsh file import /opt/ohpc/pub/examples/network/centos/ifcfg-ib0.ww
    wwsh -y file set ifcfg-ib0.ww --path=/etc/sysconfig/network-scripts/ifcfg-ib0
fi


# Assemble VNFS
wwvnfs -y --chroot ${node_chroot}


# Add the compute node hosts to the cluster
for ((i=0; i<$compute_node_count; i++)) ; do
    c_name=${compute_node_name_prefix}$(( ${i} + 1 ))
    wwsh -y node new ${c_name} --ipaddr=${c_ip[$i]}          \
                               --netmask=${internal_netmask} \
                               --hwaddr=${c_mac[$i]}         \
                               --netdev=${eth_provision}     \
                               --gateway=${sms_ip}
    wwsh -y ipmi set ${c_name} --autoconfig=1                \
                               --ipaddr=${c_bmc[$i]}         \
                               --netmask=${bmc_netmask}      \
                               --username="${bmc_username}"  \
                               --password="${bmc_password}"
done

################################################################################
# If you need to scan for the new nodes (you don't know their MAC addresses)
################################################################################
#
# wwnodescan --netdev=${eth_provision} --ipaddr=${c_ip[0]}              \
#            --netmask=${internal_netmask} --vnfs=${node_chroot_name}   \
#            --bootstrap=`uname -r`                                     \
#            ${compute_node_name_prefix}0-${compute_node_name_prefix}3
# wwsh pxe update
#

# Configure all compute nodes to boot the same Linux image
wwsh -y provision set "${compute_regex}" \
     --vnfs=${node_chroot_name}          \
     --bootstrap=`uname -r`              \
     --files=dynamic_hosts,passwd,group,shadow,genders,slurm.conf,munge.key

# Restart ganglia services to pick up hostfile changes
systemctl restart gmond.service
systemctl restart gmetad.service

# Optionally, define IPoIB network settings (required if planning to mount Lustre over IB)
if [ "${enable_infiniband}" == "true" ];then
    for ((i=0; i<$compute_node_count; i++)) ; do
        c_name=${compute_node_name_prefix}$(( ${i} + 1 ))
        wwsh -y node set ${c_name} --netdev=ib0              \
                                   --ipaddr=${c_ipoib[$i]}   \
                                   --netmask=${ipoib_netmask}
    done
    wwsh -y provision set "${compute_regex}" --fileadd=ifcfg-ib0.ww
fi

# Ensure the new node bootup settings have taken effect
systemctl restart dhcpd.service
wwsh pxe update

# Optionally, add arguments to bootstrap kernel
if [[ ! -z "${kargs}" ]]; then
    wwsh provision set "${compute_regex}" --kargs=${kargs}
fi



################################################################################
# Compute Nodes can boot at any point now
################################################################################
#
# export IPMI_PASSWORD="xxxxxx"
# for ((i=0; i<${compute_node_count}; i++)) ; do
#     ipmitool -E -I lanplus -H ${c_bmc[$i]} -U root chassis power reset
#
#     # If you want to set nodes to PXE boot by default:
#     ipmitool -E -I lanplus -H ${c_bmc[$i]} -U root chassis bootdev pxe options=persistent
# done
#
#



################################################################################
# Install Development Tools
################################################################################
yum -y groupinstall ohpc-autotools
yum -y install valgrind-ohpc
yum -y install EasyBuild-ohpc
yum -y install spack-ohpc
yum -y install R_base-ohpc



################################################################################
# Install Compilers
################################################################################
yum -y install gnu-compilers-ohpc intel-compilers-devel-ohpc



################################################################################
# Install Performance Tools
################################################################################
yum -y install papi-ohpc
yum -y install intel-itac-ohpc intel-vtune-ohpc intel-advisor-ohpc intel-inspector-ohpc
yum -y groupinstall ohpc-mpiP
yum -y groupinstall ohpc-tau



################################################################################
# Install MPI Stacks
################################################################################
yum -y install openmpi-*-ohpc mvapich2-*-ohpc intel-mpi-ohpc
yum -y groupinstall ohpc-imb
yum -y install lmod-defaults-gnu-mvapich2-ohpc



################################################################################
# Install 3rd Party Libraries and Tools
################################################################################
yum -y groupinstall ohpc-adios
yum -y groupinstall ohpc-boost
yum -y groupinstall ohpc-fftw
yum -y groupinstall ohpc-gsl
yum -y groupinstall ohpc-hdf5
yum -y groupinstall ohpc-hypre
yum -y groupinstall ohpc-metis
yum -y groupinstall ohpc-mumps
yum -y groupinstall ohpc-netcdf
yum -y groupinstall ohpc-numpy
yum -y groupinstall ohpc-openblas
yum -y groupinstall ohpc-petsc
yum -y groupinstall ohpc-phdf5
yum -y groupinstall ohpc-scalapack
yum -y groupinstall ohpc-scipy
yum -y groupinstall ohpc-trilinos



################################################################################
# Resource Manager Startup
################################################################################

# Start up the first few nodes
scontrol update nodename=${compute_node_name_prefix}[1-4] state=idle

# If all looks good, start up the remainder of the nodes
if [ ${compute_node_count} -gt 4 ];then
    scontrol update nodename=${compute_node_name_prefix}[5-$compute_node_count] state=idle
fi



################################################################################
# Install MongoDB and npm (required for MCMS management/monitoring tools)
################################################################################
echo "
[mongodb-org-3.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/3.0/x86_64/
gpgcheck=0
enabled=1
" > /etc/yum.repos.d/mongodb-org-3.0.repo
yum -y install mongodb-org python-pymongo npm
systemctl enable mongod.service
systemctl start mongod.service

# MongoDB takes a moment to start
sleep 15

# Secure MongoDB by adding an administrative user
echo "use admin
db.createUser(
    {
        user: 'root',
        pwd: '${db_root_password}',
        roles: [ { role: 'userAdminAnyDatabase', db: 'admin' } ]
    }
)
" | mongo

# Create a user for MCMS administration
echo "use mcms
db.createUser(
    {
        user: 'mcmsDBAdmin',
        pwd: '${db_mgmt_password}',
        roles: [ { role: 'dbOwner', db: 'mcms' } ]
    }
)" | mongo

# Restart MongoDB to turn on authentication
sed -i -e 's/^#security:/security:\n  authorization: enabled\n/' /etc/mongod.conf
systemctl restart mongod.service

# MongoDB administration can now be performed from the command line with:
#
#   mongo -u root -p --authenticationDatabase "admin"
#
#   > show collections
#



################################################################################
# Set up the MCMS user account with access to the MongoDB database
################################################################################
mkdir -p /var/lib/mcms
useradd --system --gid warewulf --no-create-home --home-dir /var/lib/mcms mcms
chown mcms:warewulf /var/lib/mcms
chmod 700 /var/lib/mcms

cp -a ${dependencies_dir}/etc/microway /etc/
chown -R mcms:warewulf /etc/microway
chmod 600 /etc/microway/mcms_database.conf
sed -i "s/mcms_database_password='ChangeMe'/mcms_database_password='${db_mgmt_password}'/"



################################################################################
# Set up test user account
################################################################################
groupadd users
useradd --create-home --gid users microway
wwsh file resync passwd shadow group



################################################################################
# Install NVIDIA CUDA (including the NVIDIA drivers)
################################################################################
if [[ "${enable_nvidia_gpu}" == "true" ]]; then
    # Determine the architecture of the system (e.g., x86_64)
    machine_type=$(uname --processor)

    curl -L -o cuda-repo-rhel7-7.5-18.x86_64.rpm http://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/cuda-repo-rhel7-7.5-18.x86_64.rpm

    # Install the CUDA repo on the Head Node and Compute Node image
    rpm -i cuda-repo-rhel7-7.5-18.x86_64.rpm
    mv cuda-repo-rhel7-7.5-18.x86_64.rpm ${node_chroot}/
    chroot ${node_chroot} rpm -i /cuda-repo-rhel7-7.5-18.x86_64.rpm
    rm -f ${node_chroot}/cuda-repo-rhel7-7.5-18.x86_64.rpm

    # Run the installer on the Head Node and Compute Node image
    yum --disablerepo="*" --enablerepo="cuda" list available
    yum clean all
    yum -y install cuda-7-0 cuda-7-5
    yum -y --installroot ${node_chroot} install cuda-7-0 cuda-7-5

    # NVIDIA is naughty and sets a fixed path to CUDA using a symlink.
    # This will get in the way when users want to switch from the default version.
    rm -f /usr/local/cuda ${node_chroot}/usr/local/cuda

    # Build the CUDA samples (though some will not build without other deps)
    for version in 7.0 7.5; do
        echo "Building CUDA $version samples..."
        cp -a /usr/local/cuda-${version}/samples /usr/local/cuda-${version}/tmp-build
        cd /usr/local/cuda-${version}/tmp-build
        make -j2
        mv bin/${machine_type}/linux/release ../samples-bin
        cd -
        rm -Rf /usr/local/cuda-${version}/tmp-build

        # Copy to compute node
        cp -a /usr/local/cuda-${version}/samples-bin ${node_chroot}/usr/local/cuda-${version}/
    done

    # Install the GPU monitoring/management tools
    yum -y install gpu-deployment-kit
    yum -y --installroot ${node_chroot} install gpu-deployment-kit
    pip install nvidia-ml-py

    # The nvidia-cdl tool is needed to determine CUDA device ordering
    curl -L -o nvidia-cdl.rpm https://github.com/Microway/nvidia-cdl/releases/download/v1.1.1/nvidia-cdl-1.1.1-1.x86_64.rpm
    rpm -i nvidia-cdl.rpm
    mv nvidia-cdl.rpm ${node_chroot}/
    chroot ${node_chroot} rpm -i /nvidia-cdl.rpm
    rm -f ${node_chroot}/nvidia-cdl.rpm

    # Install scripts/configuration to bring up the GPUs during boot
    cp -a ${dependencies_dir}/etc/init.d/nvidia /etc/init.d/nvidia
    cp -a ${dependencies_dir}/etc/init.d/nvidia ${node_chroot}/etc/init.d/nvidia
    cp -a ${dependencies_dir}/etc/sysconfig/nvidia /etc/sysconfig/nvidia
    cp -a ${dependencies_dir}/etc/sysconfig/nvidia ${node_chroot}/etc/sysconfig/nvidia
    # By default, we'll assume we're not bringing up GPUs in the Head Node
    chroot ${node_chroot} systemctl enable nvidia.service
    chroot ${node_chroot} systemctl start nvidia.service

    # Put the GPU health check settings in place
    cp -a ${dependencies_dir}/etc/nvidia-healthmon.conf /etc/
    cp -a ${dependencies_dir}/etc/nvidia-healthmon.conf ${node_chroot}/etc/

    # FIXME: needs to be revised for the OpenHPC module hierarchy
    # # Set up the Environment Modules for these versions of CUDA
    # mkdir -p ${dependencies_dir}/modulefiles/${machine_type}/Core/cuda
    # for version in 7.0 7.5; do
    #   cp -a ${dependencies_dir}/modulefiles/core/cuda.lua ${dependencies_dir}/modulefiles/${machine_type}/Core/cuda/${version}.lua
    #   sed -i "s/{cuda-version}/${version}/" ${dependencies_dir}/modulefiles/${machine_type}/Core/cuda/${version}.lua
    #   sed -i "s/{architecture/${machine_type}/" ${dependencies_dir}/modulefiles/${machine_type}/Core/cuda/${version}.lua
    # done
    # (cd ${dependencies_dir}/modulefiles/Core/cuda/ && ln -s 7.5.lua default)
fi



################################################################################
# Install Intel Xeon Phi coprocessor driver and tools
################################################################################
if [[ "${enable_phi_coprocessor}" == "true" ]]; then
    intel_xeonphi_mpss="http://registrationcenter.intel.com/irc_nas/8202/mpss-3.6-linux.tar"
    curl -L -o mpss-3.6-linux.tar ${intel_xeonphi_mpss}
    tar xvf mpss-3.6-linux.tar
    cd mpss-3.6/
    yum -y install kernel-headers kernel-devel
    cd src/
    rpmbuild --rebuild mpss-modules*.src.rpm
    cd ../
    mv -v ~/rpmbuild/RPMS/x86_64/mpss-modules*$(uname -r)*.rpm modules/
    yum install install modules/*.rpm
    cd ../
    modprobe mic

    OFEDFORCE=1 CHROOTDIR=${node_chroot} wwinit MIC
    yum --tolerant --installroot ${node_chroot} -y install warewulf-mic-node
    rm -f mpss-3.6-linux.tar

    # Double-check MPSS start-up on boot. Seems to be an issue.
    echo "

# If Xeon Phi coprocessors are present, double-check that MPSS has started
if [[ -z "$(ps -e | awk '/mpssd/ {print $4}')" ]] && [[ -c /dev/mic0 ]]; then
    systemctl start mpss
fi

    " >> ${node_chroot}/etc/rc.local

    # Make sure root can login to the Xeon Phi
    if [[ ! -f /root/.ssh/id_rsa ]]; then
        ssh-keygen -d rsa
        chmod 600 /root/.ssh/id_rsa
    fi
    cp -a /root/.ssh/id_rsa /root/.ssh/id_rsa.pub ${node_chroot}/root/.ssh/
    cat /root/.ssh/id_rsa.pub >> ${node_chroot}/root/.ssh/authorized_keys
    chmod 600 ${node_chroot}/root/.ssh/authorized_keys

    wwsh mic set --lookup=groups phi --mic=1
    wwsh provision set --lookup=groups phi --kargs="wwkmod=mic quiet"

    # Allow Warewulf to set consecutive addresses for the Xeon Phi devices
    wwsh node set --netdev=mic0 --ipaddr=10.100.0.0 --netmask=255.255.0.0

    # Make sure that wwfirstboot is not disabled in the configuration file
    # /etc/sysconfig/wwfirstboot.conf. Although wwfirstboot is mostly used for
    # system provisioning, it is also used for Xeon Phi provisioning.
fi



################################################################################
# Install commonly used tools on the Head Node and Compute Nodes
#
# It's better for the cluster if packages can be compiled on the compute nodes
# as easily as they can be built on the head node. It's also better for the
# users if the tools they need are available, so the nodes get a fairly full
# installation, including development packages.
#
################################################################################

declare -A mcms_package_selections
mcms_package_selections['global']="
    apr libconfuse

    cpufrequtils
    dmidecode
    fio
    freeipmi freeipmi-devel
    hdparm
    hwloc hwloc-devel
    ipmitool
    mcelog
    numactl numactl-devel
    OpenIPMI

    bc
    byacc
    emacs
    gdb
    git
    golang
    htop
    java-1.6.0-openjdk-devel java-1.7.0-openjdk-devel java-1.8.0-openjdk-devel
    libtool
    lsof
    man
    mc
    meld
    nasm
    patch
    ruby-devel
    rubygems
    screen
    smem
    strace
    tcsh
    tree
    p7zip
    unzip
    vim
    xemacs

    bridge-utils lftp ncftp nmap nmap-ncat wget

    dvipng
    firefox
    gnuplot
    graphviz graphviz-devel
    ImageMagick
    rrdtool rrdtool-devel
    texinfo texinfo-tex texlive-latex

    ncurses ncurses-libs ncurses-static

    python-netaddr python-netifaces python-psutil

    ibutils
    infiniband-diags infiniband-diags-devel
    libibcm libibcm-devel
    libibcommon libibcommon-devel
    libibmad libibmad-devel
    libibumad libibumad-devel
    libibverbs libibverbs-devel libibverbs-utils
    libmlx4
    librdmacm librdmacm-devel
    rdma

    xorg-x11-xauth xterm
"
mcms_package_selections['development']="
    apr-devel
    bzip2-devel
    expat-devel
    glibc-devel.i686 glibc-static
    gmp-devel
    gstreamer gstreamer-devel gstreamer-plugins-base-devel
    gtk+ gtk+-devel
    gtk2 gtk2-devel
    leveldb-devel
    libart_lgpl-devel
    libconfuse-devel
    libjasper-devel
    libjpeg-turbo-devel
    libmpc libmpc-devel
    libnotify libnotify-devel
    libpciaccess-devel
    libpng-devel
    libtiff-devel
    libXdmcp libXdmcp-devel
    libyaml libyaml-devel
    lua-devel
    mpfr-devel
    mysql-devel
    openssl-devel
    pcre-devel
    pygtk2
    python-devel
    python-pip
    readline-devel
    rpm-build
    SDL SDL-devel
    snappy-devel
    sqlite-devel
    tcl-devel
    tk-devel
    webkitgtk webkitgtk-devel
"
mcms_package_selections['head_node']="
    xfsdump xfsprogs yum-utils
"
mcms_package_selections['compute_node']=""


yum -y install ${mcms_package_selections['global']}      \
               ${mcms_package_selections['development']} \
               ${mcms_package_selections['head_node']}

yum -y --installroot=${node_chroot} install              \
               ${mcms_package_selections['global']}      \
               ${mcms_package_selections['development']} \
               ${mcms_package_selections['compute_node']}

# Packages which can't be installed via yum
pip install gnuplot-py plumbum
chroot ${node_chroot} pip install gnuplot-py

# The distro version of pymongo is too old to support newer credentials
pip install --upgrade pymongo

# Clear out the random entries from chrooting into the compute node environment
> ${node_chroot}/root/.bash_history

echo "
# Having BASH_ENV set makes Warewulf management scripts break.
unset BASH_ENV

" >> /root/.bashrc


################################################################################
# Complete the configuration of the Compute Node VNFS system
################################################################################
# Leave the node's logs directory intact (many tools die if this is missing)
sed -i 's|exclude += /var/log/\*|# exclude += /var/log/*  # nodes need to log|' /etc/warewulf/vnfs.conf

# Enable a VNFS directory (for hybridizing images)
sed -i 's|# hybridpath = /hybrid.*|hybridpath = /vnfs|' /etc/warewulf/vnfs/${node_chroot}.conf

# Hybridize some paths which commonly bloat the images
echo "

hybridize += /usr/local
hybridize += /opt/ohpc
hybridize += /usr/lib/golang
hybridize += /usr/lib/jvm
hybridize += /usr/lib64/nvidia
hybridize += /usr/lib64/firefox

" >> /etc/warewulf/vnfs/${node_chroot}.conf


# Re-assemble compute node VNFS with all the software changes
wwvnfs -y --chroot ${node_chroot}



################################################################################
# Set up mail forwarding (on systems which need to alert admins)
################################################################################
echo "transport_maps = hash:/etc/postfix/transport" >> /etc/postfix/main.cf
echo "*    smtp:${mail_server}" >> /etc/postfix/transport
postmap hash:/etc/postfix/transport

# If necessary, specific user accounts, such as root@cluster.domain.edu can be
# redirected to an admin account via the virtual maps:
#
#   echo "root@head.hpc.example.com admin@example.com" >> /etc/postfix/virtual
#   postmap /etc/postfix/virtual
#   echo "virtual_alias_maps = hash:/etc/postfix/virtual" >> /etc/postfix/main.cf
#

postfix reload


