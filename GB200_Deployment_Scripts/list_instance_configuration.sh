# Script to list instance configuration
LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Listing instance configuration in $COMPARTMENT_ID at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh



echo "Listing instance configuration in $COMPARTMENT_ID at $(date)"
echo "Region: $REGION"
echo "Compartment ID: $COMPARTMENT_ID"

oci --region $REGION compute-management instance-configuration list --compartment-id $COMPARTMENT_ID

echo "Completed listing instance configuration at $(date)"
