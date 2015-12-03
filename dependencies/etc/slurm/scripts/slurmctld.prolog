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
#
# This prolog script is run from the front-end SLURM server before a user's job
# is allocated compute nodes. This script is run as the SlurmUser, not as root.
#
# During execution of this script, the nodes have state POWER_UP/CONFIGURING.
# This gives us time to run longer health tests than are normally allowed in
# prolog and epilog scripts.
#
# Each NHC script is expected to finish within 2 minutes. If an error (such as
# a broken NFS mount) causes the script to run beyond 2 minutes, it will be
# terminated (which results in an error condition and drains the compute node).
#
################################################################################


# Exit if this script isn't actually running within a SLURM context
if [[ -z "$SLURM_JOB_UID" ]] || [[ -z "$SLURM_JOB_ID" ]]; then
    echo "Do not run this script manually - it is used by SLURM"
    exit 1
fi


################################################################################
# Parse the short-form node list information from SLURM. scontrol can do this,
# but we should try not to shell out. Example: node[1,4-7,18]
#
full_node_list=( )

nodename_prefix=${SLURM_JOB_NODELIST%%\[*}
nodename_postfix=${SLURM_JOB_NODELIST##*\]}
short_list=${SLURM_JOB_NODELIST##*\[}
short_list=${short_list%%\]*}

# If the 'node list' is a single node, we're done
if [[ "$nodename_prefix" == "$nodename_postfix" ]]; then
    full_node_list[0]=$SLURM_JOB_NODELIST
else
    # Break down the comma-separated list
    OLD_IFS=$IFS
    IFS=,
    for item in $short_list; do
        range_begin=${item%%-*}
        range_end=${item##*-}

        # Add in each node in the specified node range (even if it's just one node)
        for (( i=$range_begin; i<$(($range_end+1)); i++ )); do
            full_node_list[${#full_node_list[@]}]=${nodename_prefix}${i}${nodename_postfix}
        done
    done
    IFS=$OLD_IFS
fi
################################################################################


# We may have a pause here if SLURM is getting nodes ready (either by powering
# up nodes that are powered off and/or running long health checks).


################################################################################
# Wait for the nodes to complete the boot process.
# To start, we'll try one node at random. As soon as more than one node is
# responding, we'll exit and SLURM can verify they are actually up.
#
# SSH will wait up to 5 seconds per attempt; we'll wait up to another 5 seconds
retry_interval="5s"

# Specify arguments to pass to SSH
# Slurm will use a private SSH key to login as root on each compute node.
SSH_EXECUTABLE=${SSH_EXECUTABLE:-/usr/bin/ssh}
ssh_arguments="-i /var/spool/slurmd/.ssh/.poweroff-ssh-key -2 -a -x -lroot -oConnectTimeout=${retry_interval}"

# Each retry will last between 5 and 10 seconds (we'll wait 5 to 10 minutes)
retry_attempts=60
ssh_retval=999
nodes_responding=0
while [[ $ssh_retval -gt 0 ]] &&
      [[ $retry_attempts -gt 0 ]] &&
      [[ $nodes_responding -lt 2 ]];
do
    sleep $retry_interval

    random_node_index=$(( $RANDOM % ${#full_node_list[@]} ))
    random_node=${full_node_list[$random_node_index]}

    $SSH_EXECUTABLE $ssh_arguments $random_node echo
    ssh_retval=$?

    # Once nodes start responding, count them
    if [[ $ssh_retval -eq 0 ]]; then
        nodes_responding=$(( $nodes_responding + 1 ))
    fi

    retry_attempts=$(( $retry_attempts - 1 ))
done

# If we waited the whole time and no nodes are responding, error out
if [[ $ssh_retval -gt 0 ]] && [[ $nodes_responding -lt 2 ]]; then
    exit $ssh_retval
fi
################################################################################



################################################################################
# Prevent long tests from running over and over on compute nodes. While many
# cluster jobs are long-running, SLURM also supports large numbers of short-
# running jobs. We don't want multi-minute tests between each job.

# Assume that one intensive health test per day will be sufficient
LONG_HEALTH_CHECK_INTERVAL=${LONG_HEALTH_CHECK_INTERVAL:-$((60*60*24))}

# Number of seconds since epoch
current_time=$(printf "%(%s)T" "-1")

# List of nodes which need to be checked
check_node_list=( )

# Store the health check cache in memory - requires 4KB per node
cache_dir=/dev/shm/.slurmctld_health_check_cache

for compute_node in ${full_node_list[@]}; do
    # Split node cache files into several directories
    node_number=${compute_node##*[a-zA-Z-_]}
    node_dir="${cache_dir}/${node_number:0:1}"
    node_cache_file="${node_dir}/${compute_node}"

    # See if the node has ever been checked
    last_tested=0
    if [[ -f "$node_cache_file" ]]; then
        last_tested=$(< $node_cache_file)
    fi

    if (( $current_time > ($last_tested + $LONG_HEALTH_CHECK_INTERVAL) )); then
        # Node was not checked recently. Check it now.
        check_node_list[${#check_node_list[@]}]=$compute_node
    fi
done
################################################################################



################################################################################
# Start the long healthcheck script on the compute nodes in parallel.
#
LONG_HEALTH_CHECK_SCRIPT=${LONG_HEALTH_CHECK_SCRIPT:-/etc/slurm/scripts/slurm.healthcheck_long}

# Specify arguments to pass to SSH - slurm will use a private SSH key to login
# as root on each compute node. Note that the username parameter must be set
# twice (once with '%u' and once with 'root') to prevent PDSH from overwriting
# this setting with the SLURM username.
export PDSH_SSH_ARGS="-i /var/spool/slurmd/.ssh/.healthcheck-ssh-key -2 -a -x -l%u -lroot %h"
export PDSH_EXECUTABLE=${PDSH_EXECUTABLE:-/usr/bin/pdsh}

# Execute Node Health Checks on all nodes assigned to this job
$PDSH_EXECUTABLE -Sw $SLURM_JOB_NODELIST $LONG_HEALTH_CHECK_SCRIPT
pdsh_retval=$?

if [[ $pdsh_retval -gt 0 ]]; then
    exit $pdsh_retval
fi
################################################################################



################################################################################
# If we've gotten to the end cleanly, everything should have worked.
#
# Mark the compute nodes as checked.
#
for compute_node in ${check_node_list[@]}; do
    # Split node cache files into several directories
    node_number=${compute_node##*[a-zA-Z-_]}
    node_dir="${cache_dir}/${node_number:0:1}"
    node_cache_file="${node_dir}/${compute_node}"

    if [[ ! -d "$node_dir" ]]; then
        mkdir -p "$node_dir"
    fi

    echo $current_time > "$node_cache_file"
done
################################################################################


exit 0

