# Tenancy Variables
# To populate these variables, run the following command list_oke_cluster.sh.  Need to make sure Region, TENANCY_ID, COMPARTMENT_ID and a portion of the cluster_name to search for are specified before running.
REGION=""
TENANCY_ID=""
COMPARTMENT_ID=""


AD=""
WORKER_SUBNET_ID=""
WORKER_SUBNET_NSG_ID=""
POD_SUBNET_ID=""
POD_SUBNET_NSG_ID=""
IMAGE_ID=""

CLUSTER_NAME=""

#
# Compute Cluster OCID
CC_ID=

# Instance Configuration to use OCID
IC_ID=

# GPU Memory Fabric ID
GPU_MEMORY_FABRIC_ID=

# GPU Memory Fabric Cluster, GB200 - size 18
GPU_MEMORY_CLUSTER_SIZE=
