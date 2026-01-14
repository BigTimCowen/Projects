# Script to create image shape compatibility entry
LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Starting adding image compatability to image at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh



echo "Adding image compatability entry for image $IMAGE_ID with $SHAPE_NAME"
set -x 
oci compute image-shape-compatibility-entry add --image-id $IMAGE_ID --shape-name $SHAPE_NAME
set +x 

echo "Completed adding image compatability entry for image $IMAGE_ID in compartment $COMPARTMENT_ID at $(date)"
