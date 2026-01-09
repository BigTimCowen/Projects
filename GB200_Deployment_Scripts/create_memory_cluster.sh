#!/bin/bash

LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Starting creation of GPU Memory Cluster at $(date)"
echo "Sourcing Variables from variables.sh"

#
# Prerequisite:
# Create Instance configuration
#
# Create Compute Cluster
#
# Determine GB200 Memory Fabric ID
#       oci compute compute-gpu-memory-fabric list --compartment-id $TENANCY_ID

source ./variables.sh


DISPLAY_NAME="fabric-${GPU_MEMORY_FABRIC_ID: -5}"

echo "Creating GPU Memory Cluster"
oci compute compute-gpu-memory-cluster create \
  --availability-domain $AD \
  --compartment-id $COMPARTMENT_ID \
  --compute-cluster-id $CC_ID \
  --instance-configuration-id $IC_ID \
  --gpu-memory-fabric-id $GPU_MEMORY_FABRIC_ID \
  --size $GPU_MEMORY_CLUSTER_SIZE \
  --display-name $DISPLAY_NAME

echo "Ending GPU Memory Cluster creation"
