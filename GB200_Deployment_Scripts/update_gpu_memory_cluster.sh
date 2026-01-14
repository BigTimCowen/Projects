#!/bin/bash
# This script updates the gpu memory cluster to the specified size.  
# Run list_gpu_memory_clusters.sh to get the gpu memory cluster id.
# Size will be the total number of gpu nodes in the cluster.  For example, if you have 18 gpu nodes in the cluster, the size will be 18.
# usage: ./update_gpu_memory_cluster.sh <gpu_memory_cluster_id> <gpu_memory_cluster_size>

LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Starting update of gpu memory cluster at $(date)"
echo "Sourcing Variables from variables.sh"
source ./variables.sh

GPU_MEMORY_CLUSTER_ID=$1
GPU_MEMORY_CLUSTER_SIZE=$2

echo "GPU Memory Cluster ID being updated: " $GPU_MEMORY_CLUSTER_ID
echo "GPU memory Cluster being updated to size: " $GPU_MEMORY_CLUSTER_SIZE

echo "Updating to gpu-memory-cluster"

set -x
oci compute compute-gpu-memory-cluster update \
  --compute-gpu-memory-cluster-id $GPU_MEMORY_CLUSTER_ID \
  --size $GPU_MEMORY_CLUSTER_SIZE
set +x

echo "Ending update of gpu-memory-cluster"
