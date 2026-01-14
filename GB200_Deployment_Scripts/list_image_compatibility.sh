#!/bin/bash
# This script lists the image compatibility for a given image and shape in Oracle Cloud Infrastructure (OCI).

LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Listing image compatability to image at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh

echo "Listing image compatability entry for image $IMAGE_ID with $SHAPE_NAME"

set -x 
oci compute image-shape-compatibility-entry list --image-id $IMAGE_ID
set +x 

echo "Completed listing image compatability entry for image $IMAGE_ID at $(date)"
