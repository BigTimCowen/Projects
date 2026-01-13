# Script to create Compute Cluster
LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Starting creation of compute cluster at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh
DISPLAY_NAME="Name-Compute-Cluster"


echo "Creating compute cluster"
echo "Creating GPU Memory Cluster in $AD, $COMPARTMENT_ID"
echo "DISPLAY NAME - $DISPLAY_NAME"


oci compute compute-cluster create --availability-domain $AD --compartment-id $COMPARTMENT_ID --display-name $DISPLAY_NAME
echo "Compute cluster creation ended"
