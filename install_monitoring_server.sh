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
# Install the Open Monitoring Distribution (Shinken/Thruk/Check_MK)
################################################################################
rpm -Uvh "https://labs.consol.de/repo/stable/rhel7/x86_64/labs-consol-stable.rhel7.noarch.rpm"
yum -y install omd-2.10-labs-edition libdbi

# Create a monitoring 'site' for this cluster
/opt/omd/versions/default/bin/omd create hpc_monitor

su -c "omd config set ADMIN_MAIL"                               - hpc_monitor
su -c "omd config set APACHE_MODE own"                          - hpc_monitor
su -c "omd config set APACHE_TCP_ADDR 127.0.0.1"                - hpc_monitor
su -c "omd config set APACHE_TCP_PORT 5000"                     - hpc_monitor
su -c "omd config set AUTOSTART on"                             - hpc_monitor
su -c "omd config set CORE shinken"                             - hpc_monitor
su -c "omd config set CRONTAB on"                               - hpc_monitor
su -c "omd config set DEFAULT_GUI thruk"                        - hpc_monitor
su -c "omd config set DOKUWIKI_AUTH off"                        - hpc_monitor
su -c "omd config set GRAFANA on"                               - hpc_monitor
su -c "omd config set GRAFANA_TCP_PORT 8003"                    - hpc_monitor
su -c "omd config set INFLUXDB on"                              - hpc_monitor
su -c "omd config set INFLUXDB_ADMIN_TCP_PORT 8083"             - hpc_monitor
su -c "omd config set INFLUXDB_HTTP_TCP_PORT 8086"              - hpc_monitor
su -c "omd config set INFLUXDB_META_TCP_PORT 8088"              - hpc_monitor
su -c "omd config set LIVESTATUS_TCP off"                       - hpc_monitor
su -c "omd config set MKEVENTD off"                             - hpc_monitor
su -c "omd config set MOD_GEARMAN off"                          - hpc_monitor
su -c "omd config set MONGODB on"                               - hpc_monitor
su -c "omd config set MONGODB_TCP_PORT 27017"                   - hpc_monitor
su -c "omd config set MULTISITE_AUTHORISATION off"              - hpc_monitor
su -c "omd config set MULTISITE_COOKIE_AUTH off"                - hpc_monitor
su -c "omd config set MYSQL off"                                - hpc_monitor
su -c "omd config set NAGFLUX on"                               - hpc_monitor
su -c "omd config set NAGVIS_URLS check_mk"                     - hpc_monitor
su -c "omd config set NSCA off"                                 - hpc_monitor
su -c "omd config set PNP4NAGIOS off"                           - hpc_monitor
su -c "omd config set SHINKEN_ARBITER_PORT localhost:7770"      - hpc_monitor
su -c "omd config set SHINKEN_BROKER_PORT localhost:7772"       - hpc_monitor
su -c "omd config set SHINKEN_POLLER_PORT localhost:7771"       - hpc_monitor
su -c "omd config set SHINKEN_REACTIONNER_PORT localhost:7769"  - hpc_monitor
su -c "omd config set SHINKEN_SCHEDULER_PORT localhost:7768"    - hpc_monitor
su -c "omd config set SHINKEN_WEBUI_TCP_PORT 57767"             - hpc_monitor
su -c "omd config set THRUK_COOKIE_AUTH on"                     - hpc_monitor
su -c "omd config set TMPFS on"                                 - hpc_monitor

# Initialize the monitoring services and web interfaces
omd start hpc_monitor

# The default web UI will now be is available at:
#
#   http://localhost/microway_hpc/
#
#
# The default admin user for the web applications is omdadmin with password omd.
#
#
# Run the following command for administration of this site:
#
#    su - microway_hpc
#
#
# Then you can run things such as:
#
#    omd config show
#


# Fix a bug in OMD - make sure it knows Shinken is managing the Nagios config
if [[ ! -f /omd/sites/hpc_monitor/tmp/nagios/nagios.cfg ]]; then
    ln -s /omd/sites/hpc_monitor/tmp/shinken/shinken-apache.cfg   \
          /omd/sites/hpc_monitor/tmp/nagios/nagios.cfg
    chown hpc_monitor:hpc_monitor /omd/sites/hpc_monitor/tmp/nagios/nagios.cfg
fi


# Enable compatibility between Shinken and Check_MK
echo "check_submission = 'pipe'" >> /omd/sites/hpc_monitor/etc/check_mk/main.mk


# Set up authentication for Shinken
echo "define contact {
    contact_name                  omdadmin
    alias                         omdadmin admin contact
    host_notification_commands    check-mk-dummy
    service_notification_commands check-mk-dummy
    host_notification_options     n
    service_notification_options  n
    host_notification_period      24X7
    service_notification_period   24X7
}

define contactgroup {
    contactgroup_name             omdadmin
    alias                         omdadmin admin contact group
    members                       omdadmin
}" > /omd/sites/hpc_monitor/etc/nagios/conf.d/contact.cfg
chown hpc_monitor:hpc_monitor /omd/sites/hpc_monitor/etc/nagios/conf.d/contact.cfg


# Connect Shinken's webui with MongoDB
echo "define module{
    module_name      WebUI
    module_type      webui
    host             0.0.0.0       ; mean all interfaces
    port             7767
    auth_secret      ${db_mgmt_password}
    # Advanced options. Do not touch it if you don't
    # know what you are doing
    #http_backend    wsgiref
    # ; can be also : cherrypy, paste, tornado, twisted
    # ; or gevent
    modules          Apache_passwd,Mongodb
    # Modules for the WebUI.
}
define module{
    module_name      Apache_passwd
    module_type      passwd_webui
    passwd           /omd/sites/hpc_monitor/etc/htpasswd
}
define module{
  module_name Mongodb
  module_type mongodb
  uri mongodb://localhost:27017
  database shinken
}" > /omd/sites/hpc_monitor/etc/shinken/shinken-specific.d/module_webui.cfg


# Restart the services for the changes to take effect
omd restart hpc_monitor
