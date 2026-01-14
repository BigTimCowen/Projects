#!/bin/bash
# This script creates a GPU Memory Cluster in Oracle Cloud Infrastructure (OCI) for the GB200 deployment.
#
# Prerequisite:
# Create Compute Cluster
# Create Instance configuration
#
# Determine GB200 Memory Fabric ID
# ./list_gpu_memory_fabrics.sh 
# If no GPU Memory Fabric exists, work with your Oracle team to determine the issue.

LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Starting creation of GPU Memory Cluster at $(date)"
echo "Sourcing Variables from variables.sh"
source ./variables.sh

DISPLAY_NAME="fabric-${GPU_MEMORY_FABRIC_ID: -5}"

echo "Creating GPU Memory Cluster"
set -x
oci compute compute-gpu-memory-cluster create \
  --availability-domain $AD \
  --compartment-id $COMPARTMENT_ID \
  --compute-cluster-id $CC_ID \
  --instance-configuration-id $IC_ID \
  --gpu-memory-fabric-id $GPU_MEMORY_FABRIC_ID \
  --size $GPU_MEMORY_CLUSTER_SIZE \
  --display-name $DISPLAY_NAME
set +x

echo "Ending GPU Memory Cluster creation"
