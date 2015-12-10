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
## This script sets up a monitoring server for an OpenHPC cluster
##
##
## This script should be run on a monitoring server on the same network as the
## cluster's Head/Master Node - also referred to as the System Management Server
## (SMS). This script presumes that a Red Hat derivative (CentOS, SL, etc) has
## just been installed (with vanilla configuration).
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
# If enabled, disable auto-update on this server.
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
# Disable X-Windows since this is typically a headless server
################################################################################
systemctl set-default multi-user.target



################################################################################
# Create a group for HPC administrators
################################################################################
groupadd hpc-admin



################################################################################
# Install the monitoring tools (Shinken/Thruk/Check_MK)
################################################################################
useradd --system shinken --home-dir /tmp --no-create-home

yum install python-pip
pip install shinken

systemctl enable shinken.service
systemctl start shinken.service

