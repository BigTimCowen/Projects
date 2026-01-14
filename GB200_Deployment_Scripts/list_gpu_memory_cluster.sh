#!/bin/bash
# This script lists the GPU Memory Clusters in the specified compartment.

LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Listing GPU Memory Clusters at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh
set -x
oci compute compute-gpu-memory-cluster list --compartment-id $COMPARTMENT_ID
set +x 

echo "Completed listing GPU Memory Clusters at $(date)"