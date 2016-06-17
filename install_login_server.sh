#!/bin/bash
################################################################################
######################## Microway Cluster Management Software (MCMS) for OpenHPC
################################################################################
#
# Copyright (c) 2016 by Microway, Inc.
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
## This script sets up a Login server for an OpenHPC cluster. A Login server
## sits on your network and accepts user logins (logging them into the cluster).
##
##
## This script should be run on the cluster's Head Node/SMS Server. It will
## create an OpenHPC/Warewulf image that can be deployed to the login server(s).
##
## The Login servers should be connected to two networks:
##   * the internal cluster network (to communicate with the Head/Compute Nodes)
##   * the campus/institute's network (for user access)
##
##
## Please note that certain design/configuration choices are made by this script
## which may not be compatible with all sites. Efforts are made to maintain
## portability, but compatibility cannot be guaranteed.
##
################################################################################


# Set the default names of the VNFS images
export node_chroot_name=centos-7
export login_chroot_name=login



################################################################################
# Create the new VNFS
################################################################################
ohpc_vnfs_clone ${node_chroot_name} ${login_chroot_name}
export login_chroot=/opt/ohpc/admin/images/${login_chroot_name}

# Hybridize some paths which commonly bloat the images
echo "

# We will be mounting this from the Head Node via NFS
exclude += /opt/ohpc

# These paths will be made available to nodes via NFS
hybridize += /usr/local
hybridize += /usr/lib/golang
hybridize += /usr/lib/jvm
hybridize += /usr/lib64/nvidia
hybridize += /usr/lib64/firefox

" >> /etc/warewulf/vnfs/${login_chroot_name}.conf



################################################################################
# Disable the services that are only needed on Compute Nodes
################################################################################
chroot ${login_chroot} systemctl disable munge.service
chroot ${login_chroot} systemctl disable slurm.service



################################################################################
# Ensure all users can login to this system
################################################################################
sed -i 's/- : ALL EXCEPT root hpc-admin : ALL//' ${login_chroot}/etc/security/access.conf
sed -i 's/# Reject users who do not have jobs running on this node//' ${login_chroot}/etc/pam.d/sshd
sed -i 's/account    required     pam_slurm.so//' ${login_chroot}/etc/pam.d/sshd



################################################################################
# Configure the second network interface
################################################################################
mkdir -p /etc/warewulf/files/login_servers/
echo "
DEVICE=eth0
BOOTPROTO=static
ONBOOT=yes
ZONE=trusted
IPADDR=%{NETDEVS::ETH0::IPADDR}
NETMASK=%{NETDEVS::ETH0::NETMASK}
GATEWAY=%{NETDEVS::ETH0::GATEWAY}
HWADDR=%{NETDEVS::ETH0::HWADDR}
MTU=%{NETDEVS::ETH0::MTU}
" > /etc/warewulf/files/login_servers/ifcfg-eth0.ww
wwsh file import /etc/warewulf/files/login_servers/ifcfg-eth0.ww    \
                 --name=loginServers_ifcfg-eth0                     \
                 --path=/etc/sysconfig/network-scripts/ifcfg-eth0
echo "
DEVICE=eth1
BOOTPROTO=static
ONBOOT=yes
ZONE=public
IPADDR=%{NETDEVS::ETH1::IPADDR}
NETMASK=%{NETDEVS::ETH1::NETMASK}
GATEWAY=%{NETDEVS::ETH1::GATEWAY}
HWADDR=%{NETDEVS::ETH1::HWADDR}
MTU=%{NETDEVS::ETH1::MTU}
" > /etc/warewulf/files/login_servers/ifcfg-eth1.ww
wwsh file import /etc/warewulf/files/login_servers/ifcfg-eth1.ww    \
                 --name=loginServers_ifcfg-eth1                     \
                 --path=/etc/sysconfig/network-scripts/ifcfg-eth1



################################################################################
# Configure the firewall
################################################################################
# Ensure the firewall is active (it's not usually enabled on compute nodes)
yum -y --installroot=${login_chroot} install firewalld
chroot ${login_chroot} systemctl enable firewalld.service

# By default, only SSH is allowed in on the public-facing network interface.
# We can allow more services here, if desired:
#
# chroot ${login_chroot} firewall-offline-cmd --zone=public --add-service=http
#



################################################################################
# Re-assemble Login server VNFS with all the changes
################################################################################
# Clear out the random entries from chrooting into the VNFS image
> ${login_chroot}/root/.bash_history

# Rebuild the VNFS
wwvnfs -y --chroot ${login_chroot}



echo "

The Login server software image is now ready for use. To deploy to a server, you
should run something similar to the commands below:

wwsh node clone node1 login1

wwsh provision set login1 --fileadd=loginServers_ifcfg-eth0 --vnfs=login
wwsh provision set login1 --fileadd=loginServers_ifcfg-eth1 --vnfs=login

wwsh node set login1 --netdev=eth0 --ipaddr=10.0.254.253 --netmask=255.255.0.0 --hwaddr=00:aa:bb:cc:dd:ee --mtu=9000 --fqdn=login1.hpc.example.com
wwsh node set login1 --netdev=eth1 --ipaddr=<campus IP address> --netmask=<campus netmask> --gateway=<campus gateway> --mtu=9000 --hwaddr=00:aa:bb:cc:dd:ef
wwsh node set login1 --netdev=ib0 --ipaddr=10.10.254.253 --netmask=255.255.0.0
wwsh node set login1 --domain=hpc.example.com
wwsh ipmi set login1 --ipaddr=10.13.254.253

"
