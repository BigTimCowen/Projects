LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Listing GPU Memory Fabrics at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh
oci compute compute-gpu-memory-fabric list --compartment-id $TENANCY_ID
ubuntu@o-azknnz:~/gb200_deployment_scripts$ cat list_gpu_memory_cluster.sh
LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Listing GPU Memory Clusters at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh
oci compute compute-gpu-memory-cluster list --compartment-id $COMPARTMENT_ID
ubuntu@o-azknnz:~/gb200_deployment_scripts$ cat update_gpu_memory_cluster.sh
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
oci compute compute-gpu-memory-cluster update \
  --compute-gpu-memory-cluster-id $GPU_MEMORY_CLUSTER_ID \
  --size $GPU_MEMORY_CLUSTER_SIZE
echo "Ending update of gpu-memory-cluster"
