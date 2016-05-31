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
## Instructions for setting up Singularity on a CentOS system
##
################################################################################

# Grab the machine architecture (most commonly x86_64)
machine_arch=$(uname -m)

# Set the default node VNFS chroot if one is not already set
node_chroot="${node_chroot:-/opt/ohpc/admin/images/centos-7/}"

git clone -b master --depth empty https://github.com/gmkurtzer/singularity.git

cd singularity/
sh ./autogen.sh
make dist
rpmbuild -ta singularity-[0-9]*.tar.gz
cd ../
rm -Rf singularity

yum -y install ~/rpmbuild/RPMS/${machine_arch}/singularity-[0-9]*.rpm
yum -y --installroot=${node_chroot} install ~/rpmbuild/RPMS/${machine_arch}/singularity-[0-9]*.rpm

