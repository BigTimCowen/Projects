#!/bin/bash
# This script creates a compute cluster in OCI using the OCI CLI. It sources variables from a separate file and logs the output to a file.
# Feel free to modify the DISPLAY_NAME variable

LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Starting creation of compute cluster at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh
COMPUTE_CLUSTER_DISPLAY_NAME=${COMPUTE_CLUSTER_DISPLAY_NAME}


echo "Creating compute cluster"
echo "Creating GPU Memory Cluster in $AD, $COMPARTMENT_ID"
echo "Compute Cluster Display Name - $COMPUTE_CLUSTER_DISPLAY_NAME"

set -x 
oci compute compute-cluster create --availability-domain $AD --compartment-id $COMPARTMENT_ID --display-name $COMPUTE_CLUSTER_DISPLAY_NAME
set +x 

echo "Compute cluster creation ended"
