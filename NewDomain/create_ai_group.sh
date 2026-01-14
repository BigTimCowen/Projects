# Script to create ai group in domain
LOGFILE="create_group_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Creating group in domain in $TENANCY_ID at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh
AI_DOMAIN_ID=$(oci iam domain list --compartment-id $TENANCY_OCID --query "data[?\"description\"==`'"$DOMAIN_DESCRIPTION"'`].id | [0]" --raw-output)

echo "Creating group in $DOMAIN_NAME in compartment $TENANCY_ID at $(date)"
set -x 
oci idendity-domains group create --compartment-id $$TENANCY_ID --name $AI_GROUP_NAME --description "Administrator for AI Infrastructure" --domain-id $AI_DOMAIN_ID --wait-for-state "ACTIVE" --max-wait-seconds 300
set +x 

echo "Completed creating group in $DOMAIN_NAME at $(date)"