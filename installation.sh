#!/bin/bash
################################################################################
######################## Microway Cluster Management Software (MCMS) for OpenHPC
################################################################################
#
# Copyright (c) 2015 by Microway, Inc.
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
## configuration). It builds a node image with support for InfiniBand and GPUs.
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
# Install SaltStack, which provides distribution-agnostic configuration mgmt
################################################################################
yum -y install salt-minion
#
# On the Head Node, Salt will be configured for master-less operation
sed -i "s/#file_client:.*/file_client: local/" /etc/salt/minion



################################################################################
# Add the OpenHPC repository and install the baseline OpenHPC packages
################################################################################
curl ${ohpc_repo} -o /etc/yum.repos.d/OpenHPC:1.0.repo

yum -y install docs-ohpc
yum -y groupinstall ohpc-base
yum -y groupinstall ohpc-warewulf
yum -y install warewulf-ipmi-ohpc

# Create a group for HPC administrators
groupadd hpc-admin



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

    systemctl enable rdma
    systemctl start rdma

    systemctl enable opensm
    systemctl start opensm
fi



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
systemctl restart httpd


# TFTP
sed -i -r "s/^\s+disable\s+= yes/       disable = no/" /etc/xinetd.d/tftp
systemctl restart xinetd


# MariaDB Database
systemctl enable mariadb.service
systemctl restart mariadb


# NFS Exports
echo "

/home         *(rw,no_subtree_check,fsid=10,no_root_squash)
/opt          *(ro,no_subtree_check,fsid=11)

" >> /etc/exports
exportfs -a
systemctl restart nfs



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
cp -af /etc/slurm/cgroup ${node_chroot}/etc/slurm/cgroup
cp ${dependencies_dir}/etc/slurm/cgroup.conf /etc/slurm/
cp ${dependencies_dir}/etc/slurm/cgroup.conf ${node_chroot}/etc/slurm/
cp ${dependencies_dir}/etc/slurm/cgroup_allowed_devices_file.conf /etc/slurm/
cp ${dependencies_dir}/etc/slurm/cgroup_allowed_devices_file.conf ${node_chroot}/etc/slurm/

# Setup the plugin stack
cp ${dependencies_dir}/etc/slurm/plugstack.conf /etc/slurm/
cp ${dependencies_dir}/etc/slurm/plugstack.conf ${node_chroot}/etc/slurm/
mkdir -p /etc/slurm/plugstack.conf.d
cp ${dependencies_dir}/etc/slurm/plugstack.conf.d/x11.conf /etc/slurm/plugstack.conf.d/
cp -af /etc/slurm/plugstack.conf.d ${node_chroot}/etc/slurm/plugstack.conf.d

# Put the prolog/epilog/healthcheck scripts in place
mkdir -p {,${node_chroot}}/etc/slurm/scripts
cp -a ${dependencies_dir}/etc/slurm/scripts/* /etc/slurm/scripts/
cp -a ${dependencies_dir}/etc/slurm/scripts/* ${node_chroot}/etc/slurm/scripts/

# Set up SLURM log rotation
cp ${dependencies_dir}/etc/logrotate.d/slurm /etc/logrotate.d/
cp ${dependencies_dir}/etc/logrotate.d/slurm ${node_chroot}/etc/logrotate.d/

# Ensure the proper SLURM running state and log directories are in place
mkdir -p {,${node_chroot}}/var/{run,spool}/slurmd
mkdir -p {,${node_chroot}}/var/log/slurm
chown slurm:slurm {,${node_chroot}}/var/{run,spool}/slurmd
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
     "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'$(hostname -s)' IDENTIFIED BY '${db_mgmt_password}';" \
     "FLUSH PRIVILEGES;" \
     | mysql -u root

# Start up the SLURM services on the Head Node
systemctl enable munge
systemctl start munge
systemctl enable slurm
systemctl start slurm
systemctl enable slurmdbd
systemctl start slurmdbd

# Set up SLURM accounting information. You must define clusters before you add
# accounts, and you must add accounts before you can add users.
sacctmgr add cluster ${cluster_acct_hierarchy['cluster_name']}
sacctmgr add account ${cluster_acct_hierarchy['default_organization']} \
    description="${cluster_acct_hierarchy['default_organization_description']}"
sacctmgr add account ${cluster_acct_hierarchy['default_account']} \
    description="${cluster_acct_hierarchy['default_account_description']}" \
    organization=${cluster_acct_hierarchy['default_organization']}



################################################################################
# Set up Warewulf access to the SQL database
################################################################################
mysqladmin create warewulf
sed -i "s/database user.*/database user = warewulf/" /etc/warewulf/database-root.conf
sed -i "s/database password.*/database password = ${db_mgmt_password}/" /etc/warewulf/database-root.conf
echo "GRANT ALL ON warewulf.* TO 'warewulf'@'localhost' IDENTIFIED BY '${db_mgmt_password}';" \
     "GRANT ALL ON warewulf.* TO 'warewulf'@'$(hostname -s)' IDENTIFIED BY '${db_mgmt_password}';" \
     "FLUSH PRIVILEGES;" \
     | mysql -u root


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
# Create the Compute Node image with OpenHPC in Warewulf
################################################################################

# Initialize the compute node chroot installation
export node_chroot=/opt/ohpc/admin/images/centos-7
if [[ ! -z "${BOS_MIRROR}" ]]; then
    sed -i -r "s#^YUM_MIRROR=(\S+)#YUM_MIRROR=${BOS_MIRROR}#" /usr/libexec/warewulf/wwmkchroot/centos-7.tmpl
fi
wwmkchroot centos-7 ${node_chroot}


# Distribute root's SSH keys across the cluster
wwinit ssh_keys
cat ~/.ssh/cluster.pub >> ${node_chroot}/root/.ssh/authorized_keys


# Revoke SSH access to all compute nodes (except for root and admins)
if [[ "${restrict_user_ssh_logins}" == "true" ]]; then
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


if [[ "${enable_infiniband}" == "true" ]]; then
    yum -y --installroot=${node_chroot} groupinstall "InfiniBand Support"
    echo "
# Allow user processes to pin more memory (required for InfiniBand/RDMA)
*       soft    memlock         unlimited
*       hard    memlock         unlimited
" > ${node_chroot}/etc/security/limits.d/rdma.conf

    chroot ${node_chroot} systemctl enable rdma
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

chroot ${node_chroot} systemctl enable ntpd


# NFS mounts
echo "

# NFS mounts from the Head Node
${sms_ip}:/home         /home         nfs nfsvers=3,rsize=1024,wsize=1024,cto 0 0
${sms_ip}:/opt/ohpc/pub /opt/ohpc/pub nfs nfsvers=3 0 0
" >> ${node_chroot}/etc/fstab


# Link the files which will be automatically synced to the nodes periodically
wwsh file import /etc/passwd
wwsh file import /etc/group
wwsh file import /etc/shadow
wwsh file import /etc/slurm/slurm.conf
wwsh file import /etc/munge/munge.key

if [ ${enable_infiniband} == "true" ];then
    wwsh file import /opt/ohpc/pub/examples/network/centos/ifcfg-ib0.ww
    wwsh -y file set ifcfg-ib0.ww --path=/etc/sysconfig/network-scripts/ifcfg-ib0
fi



################################################################################
# Add to the stub for the /etc/hosts file
################################################################################
echo "


################################################################################
#
# WARNING: the values below were configured and set for your cluster. Changing
# these values after the fact can break the cluster - take care.
#
# Specific items which you should watch out for:
#
#   * more than one line for any particular host name (e.g., head)
#   * more than one line for any one IP address (e.g., 127.0.0.1)
#
#
# Also take note that the cluster will automatically add additional entries as
# you add more compute nodes. In most cases, you do not need to edit this file.
#
################################################################################


" >> /etc/hosts



################################################################################
# Ensure the PCI devices IDs are up to date
################################################################################
update-pciids
chroot ${node_chroot} update-pciids



################################################################################
# Install Ganglia on the Head Node and Compute Nodes
################################################################################
yum -y groupinstall ohpc-ganglia
yum -y --installroot=${node_chroot} install ganglia-gmond-ohpc

systemctl enable gmond
systemctl enable gmetad

systemctl start gmond
systemctl start gmetad

chroot ${node_chroot} systemctl enable gmond

for i in httpd apache2; do
    if [ -d /etc/$i ]; then
        sed -i "s/Require local/Require all granted/" /etc/$i/conf.d/ganglia-ohpc.conf
    fi
done

systemctl try-restart httpd



################################################################################
# Install Intel Cluster Checker on the Head Node and Compute Nodes
################################################################################
yum -y install intel-clck-ohpc
yum -y --installroot=${node_chroot} install intel-clck-ohpc



################################################################################
# If desired, configure the Lustre parallel filesystem mount
################################################################################
if [ ${enable_lustre_client} -eq 1 ];then
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

# Driver and bridging capability for Intel(R) Xeon Phi(tm) coprocessors
drivers += extra/mic.ko
drivers += bridge

# Required for NVIDIA GPUs
drivers += extra/nvidia.ko
drivers += extra/nvidia-uvm.ko

# Required to load Lustre client
drivers += updates/kernel/
" >> /etc/warewulf/bootstrap.conf

# Update the bootstrap image for the current Linux kernel version
wwbootstrap `uname -r`


# Assemble VNFS
wwvnfs -y --chroot ${node_chroot}

# Add the compute node hosts to the cluster
for ((i=0; i<$compute_node_count; i++)) ; do
    c_name=${compute_node_name_prefix}$(( ${i} + 1 ))
    wwsh -y node new ${c_name} --ipaddr=${c_ip[$i]}          \
                               --netmask=${internal_netmask} \
                               --hwaddr=${c_mac[$i]}         \
                               --netdev=${eth_provision}
    wwsh -y ipmi set ${c_name} --autoconfig=1                \
                               --ipaddr=${c_bmc[$i]}         \
                               --netmask=${bmc_netmask}      \
                               --username="${bmc_username}"  \
                               --password="${bmc_password}"
done

# Configure all compute nodes to boot the same Linux image
wwsh -y provision set "${compute_regex}" \
     --vnfs=centos-7                     \
     --bootstrap=`uname -r`              \
     --files=dynamic_hosts,passwd,group,shadow,slurm.conf,munge.key

# Restart ganglia services to pick up hostfile changes
systemctl restart gmond
systemctl restart gmetad

# Optionally, define IPoIB network settings (required if planning to mount Lustre over IB)
if [ ${enable_infiniband} -eq 1 ];then
    for ((i=0; i<$compute_node_count; i++)) ; do
        c_name=${compute_node_name_prefix}$(( ${i} + 1 ))
        wwsh -y node set ${c_name} --netdev=ib0              \
                                   --ipaddr=${c_ipoib[$i]}   \
                                   --netmask=${ipoib_netmask}
    done
    wwsh -y provision set "${compute_regex}" --fileadd=ifcfg-ib0.ww
fi

# Ensure the new node bootup settings have taken effect
systemctl restart dhcpd
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
#     ipmitool -E -I lanplus -H ${c_bmc[$i]} -U bmc_username chassis power reset
# done
#



################################################################################
# Install Development Tools
################################################################################
yum -y groupinstall ohpc-autotools
yum -y install valgrind-ohpc
yum -y install EasyBuild-ohpc
yum -y install R_base-ohpc



################################################################################
# Install Compilers
################################################################################
yum -y install gnu-compilers-ohpc intel-compilers-devel-ohpc



################################################################################
# Install Performance Tools
################################################################################
yum -y install papi-ohpc
yum -y install intel-itac-ohpc
yum -y install intel-vtune-ohpc
yum -y install intel-advisor-ohpc
yum -y install intel-inspector-ohpc
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
pdsh -w ${compute_node_name_prefix}[1-4] systemctl enable munge
pdsh -w ${compute_node_name_prefix}[1-4] systemctl start munge
pdsh -w ${compute_node_name_prefix}[1-4] systemctl enable slurm
pdsh -w ${compute_node_name_prefix}[1-4] systemctl start slurm
scontrol update nodename=${compute_node_name_prefix}[1-4] state=idle

# If all looks good, start up the remainder of the nodes
if [ ${compute_node_count} -gt 4 ];then
    pdsh -w ${compute_node_name_prefix}[5-$compute_node_count] systemctl enable munge
    pdsh -w ${compute_node_name_prefix}[5-$compute_node_count] systemctl start munge
    pdsh -w ${compute_node_name_prefix}[5-$compute_node_count] systemctl enable slurm
    pdsh -w ${compute_node_name_prefix}[5-$compute_node_count] systemctl start slurm
    scontrol update nodename=${compute_node_name_prefix}[5-$compute_node_count] state=idle
fi



################################################################################
# Install MongoDB database (required for MCMS management/monitoring tools)
################################################################################
yum install mongodb mongodb-server python-pymongo
systemctl enable mongod
systemctl start mongod



################################################################################
# Set up test user account
################################################################################
groupadd users
useradd --create-home --gid users microway
wwsh file resync passwd shadow group



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
    memtester
    numactl numactl-devel
    OpenIPMI

    bc
    byacc
    emacs
    git
    golang
    htop
    java-1.6.0-openjdk-devel java-1.7.0-openjdk-devel java-1.8.0-openjdk-devel
    man
    mc
    meld
    nasm
    patch
    ruby-devel
    rubygems
    screen
    smem
    tcsh
    tree
    unrar
    unzip
    vim
    xemacs

    bridge-utils lftp ncftp nmap nmap-ncat wget

    dvipng
    firefox
    gnuplot gnuplot-py
    graphviz graphviz-devel
    ImageMagick
    rrdtool rrdtool-devel
    texinfo texinfo-tex texlive-latex

    ncurses ncurses-libs ncurses-static

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
    readline-devel
    SDL SDL-devel
    snappy-devel
    sqlite-devel
    tcl-devel
    tk-devel
    webkitgtk webkitgtk-devel
"
mcms_package_selections['head_node']="
    xfsdump xfsprogs yum-downloadonly
"
mcms_package_selections['compute_node']=""


yum -y install ${mcms_package_selections['global']}      \
               ${mcms_package_selections['development']} \
               ${mcms_package_selections['head_node']}

yum -y --installroot=${node_chroot} install              \
               ${mcms_package_selections['global']}      \
               ${mcms_package_selections['development']} \
               ${mcms_package_selections['compute_node']}

# Re-assemble compute node VNFS with all the software changes
wwvnfs -y --chroot ${node_chroot}


