# Script to create image shape compatibility entry
LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Listing image compatability to image at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh



echo "Listing image compatability entry for image $IMAGE_ID with $SHAPE_NAME"

oci compute image-shape-compatibility-entry list --image-id $IMAGE_ID

echo "Completed listing image compatability entry for image $IMAGE_ID at $(date)"
