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
#
# Provide helpful messages for the start and end of a batch job.
#
################################################################################

# Exit if this script isn't actually running within a SLURM context
if [[ -z "$SLURM_JOB_UID" ]] || [[ -z "$SLURM_JOB_ID" ]]; then
    echo "Do not run this script manually - it is used by SLURM"
    exit 1
fi


echo "
################################################################################
# JOB DETAILS
#
# Job started at $(date +"%F %T")
# Job ID number: $SLURM_JOBID
#
# Starting from host: $(hostname)
# The following compute nodes will be used: $SLURM_NODELIST
#"

NPROCS=$(( $SLURM_NTASKS * $SLURM_CPUS_PER_TASK ))
NODES=$SLURM_JOB_NUM_NODES
NUM_SOCKETS=$((`grep 'physical id' /proc/cpuinfo | sort -u | tail -n1 | cut -d" " -f3` + 1))
NUM_CORES=$(grep siblings /proc/cpuinfo | head -n1 | cut -d" " -f2)

echo "#
# Using $NPROCS processes across $NODES nodes.
# Reserving $SLURM_MEM_PER_NODE MB of memory per node.
#
# The node starting this job has:
#
# $NUM_SOCKETS CPU sockets with $NUM_CORES cores each -- $(grep -m1 'model name' /proc/cpuinfo)
# System memory: $(awk '/MemTotal/ {print $2 $3}' /proc/meminfo)
#"

# Check for GPUs and print their status
if [[ -n "$CUDA_VISIBLE_DEVICES" && "$CUDA_VISIBLE_DEVICES" != "NoDevFiles" ]]; then
    GPUS_PER_NODE=$(echo $CUDA_VISIBLE_DEVICES | sed 's/,/ /g' | wc --words)

    first_index=$(echo $CUDA_VISIBLE_DEVICES | sed 's/,.*//')
    GPU_TYPE=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader --id=$first_index | sed 's/ /_/g')

    echo "#
# NVIDIA CUDA device IDs in use: $CUDA_VISIBLE_DEVICES
#
# Full list of GPU devices
# $(nvidia-smi)
#"
fi

# Check for Xeon Phi Coprocessors and print their status
if [[ -n "$OFFLOAD_DEVICES" ]]; then
    echo "#
# Xeon Phi device IDs in use: $OFFLOAD_DEVICES
#
# $(micinfo)
#"
fi


# Check for storage devices
STORAGE_DEVICES=$(awk '!/Attached devices/' /proc/scsi/scsi)
if [[ -n "$STORAGE_DEVICES" ]]; then
    echo "#
# Storage devices attached to this node:
# $STORAGE_DEVICES
#"
else
    echo "#
# No storage devices are attached to this node.
#"
fi


echo "#
# Changing to working directory $SLURM_SUBMIT_DIR
#
################################################################################

"


################################################################################
#
# The section below will be run when the job has finished
#
################################################################################

# Trap all exits (both with and without errors)
trap exit_handler EXIT

# Remap errors and interrupts to exit (to prevent two calls to the handler)
trap exit ERR INT TERM

exit_handler() {
    local error_code="$?"
    local exit_time=$(date +'%F %T')

    # If there was an error, report it.
    if [ "$error_code" -gt 0 ]; then
        echo "

################################################################################
#
# WARNING! Job exited abnormally at $exit_time with error code: $error_code
#
################################################################################"

    # If the job completed successfully, report success.
    else
        echo "

################################################################################
#
# Job finished successfully at $exit_time
#
################################################################################"
    fi

    exit $error_code
}
