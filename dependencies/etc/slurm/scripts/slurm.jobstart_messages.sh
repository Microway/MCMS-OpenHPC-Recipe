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
# Provide helpful messages for the start and end of a batch job.
#
# This 'library' script should not be called directly.
# Include it in your scripts with:
#    source slurm.jobstart_messages.sh
#
################################################################################


echo Script started at $(date +"%F %T")
echo Job ID number $SLURM_JOBID
echo Starting from host $(hostname)
echo
echo The following compute nodes will be used: $SLURM_NODELIST
echo

NPROCS=$SLURM_NTASKS
NODES=$SLURM_JOB_NUM_NODES
NUM_SOCKETS=$((`grep 'physical id' /proc/cpuinfo | sort -u | tail -n1 | cut -d" " -f3` + 1))
NUM_CORES=$(grep siblings /proc/cpuinfo | head -n1 | cut -d" " -f2)

echo Using $NPROCS processors across $NODES nodes
echo $NUM_SOCKETS CPU sockets with $NUM_CORES cores each -- $(grep -m1 'model name' /proc/cpuinfo)
echo System memory: $(grep MemTotal /proc/meminfo)
echo

# Check for GPUs and print their status
if [[ -n "$CUDA_VISIBLE_DEVICES" && "$CUDA_VISIBLE_DEVICES" != "NoDevFiles" ]]; then
    GPUS_PER_NODE=$(echo $CUDA_VISIBLE_DEVICES | sed 's/,/ /g' | wc --words)

    # This assumes the nodes are homogeneous (all GPUs are the same type)
    first_index=$(echo $CUDA_VISIBLE_DEVICES | sed 's/,.*//')
    GPU_TYPE=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader --id=$first_index | sed 's/ /_/g')

    echo NVIDIA CUDA device IDs in use: $CUDA_VISIBLE_DEVICES
    echo
    nvidia-smi
    echo
fi

# Check for Xeon Phi Coprocessors and print their status
if [[ -n "$OFFLOAD_DEVICES" ]]; then
    echo Xeon Phi device IDs in use: $OFFLOAD_DEVICES
    echo
    micinfo
    echo
fi


# Check for storage devices
STORAGE_DEVICES=$(awk '!/Attached devices/' /proc/scsi/scsi)
if [[ -n "$STORAGE_DEVICES" ]]; then
    echo 'Locally-attached storage devices on this node:'
    echo "$STORAGE_DEVICES"
else
    echo 'No storage devices are directly attached to this node.'
fi
echo; echo;


# Change to the working directory
echo Changing to working directory $SLURM_SUBMIT_DIR
cd $SLURM_SUBMIT_DIR
echo; echo;


# Trap all exits (both with and without errors)
trap exit_handler EXIT

# Remap errors and interrupts to exit (to prevent two calls to the handler)
trap exit ERR INT TERM

exit_handler() {
    local error_code="$?"

    # Show final information:
    echo Script finished at $(date +"%F %T")

    # If there was an error, report it.
    if [ "$error_code" -gt 0 ]; then
        echo
        echo WARNING! Script exited abnormally with error code: $error_code
        echo
    fi

    exit $error_code
}
