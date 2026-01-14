# Tenancy Variables
# To populate these variables, run the following command list_oke_cluster.sh.  Need to make sure Region, TENANCY_ID, COMPARTMENT_ID and a portion of the cluster_name to search for are specified before running.
REGION=""
TENANCY_ID=""
DOMAIN_NAME="AI-Domain"
DOMAIN_DESCRIPTION="AI Domain for AI Infrastructure"
AI_DOMAIN_ID=""
AI_GROUP_NAME="AI-Administrators"

# Compartment where the OKE Cluster and worker nodes will be created
COMPARTMENT_ID=""


# OCI AD name for the region used.
# oci iam availability-domain list --compartment-id $COMPARTMENT_OCID --query 'data[0].name' --region $REGION --raw-output
AD=""

# OKE Worker and POD Subnets
WORKER_SUBNET_ID=""
WORKER_SUBNET_NSG_ID=""
POD_SUBNET_ID=""
POD_SUBNET_NSG_ID=""

# Image to be used for the OKE Cluster / Worker Nodes.
IMAGE_ID=""

# OKE Cluster Name to search for in tenancy
CLUSTER_NAME=""
SHAPE_NAME="BM.GPU.GB200-v3.4"

# Comparmtnet name to search for in tenancy
COMPARTMENT_NAME=""

#
# Compute Cluster OCID
CC_ID=

# Instance Configuration to use OCID
IC_ID=

# GPU Memory Fabric ID
GPU_MEMORY_FABRIC_ID=

# GPU Memory Fabric Cluster, GB200 - size 18
GPU_MEMORY_CLUSTER_SIZE=
