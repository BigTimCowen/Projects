LOGFILE="list_tenancy_information.log"
exec > >(tee -a  $LOGFILE) 2>&1

set -euo pipefail  # Exit on error, undefined variables, pipe failures

# Check if variables.sh exists
if [[ ! -f ./variables.sh ]]; then
    echo "ERROR: variables.sh not found" >&2
    exit 1
fi

echo "Listing Tenancy Information at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh

if [ -n "$OCI_TENANCY" ]; then
  echo "OCI_TENANCY environment variable is set to: $OCI_TENANCY"
  set -x  # Enable debug output to log file
    TENANCY_OCID=$OCI_TENANCY
  set +x  # Enable debug output to log file  
else
    set -x  # Enable debug output to log file
    TENANCY_OCID=`curl -sH "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/ | jq -r .tenantId`
    set +x  # Enable debug output to log file
fi

set -x  # Enable debug output to log file
COMPARTMENT_OCID=$(oci iam compartment list --compartment-id $TENANCY_OCID  --compartment-id-in-subtree true  --all |  jq -r --arg name "$COMPARTMENT_NAME" '.data[] | select(.name | contains($name)) | .id')
#AD1=$(oci iam availability-domain list --compartment-id $TENANCY_OCID --query 'data[0].name' --region $REGION --raw-output)
#AD2=$(oci iam availability-domain list --compartment-id $TENANCY_OCID --query 'data[1].name' --region $REGION --raw-output)
#AD3=$(oci iam availability-domain list --compartment-id $TENANCY_OCID --query 'data[2].name' --region $REGION --raw-output)
DEFAULT_DOMAIN=$(oci iam domain list --compartment-id $TENANCY_OCID --query "data[?\"display-name\"=='Default'].id | [0]" --raw-output)
AI_DOMAIN_OCID=$(oci iam domain list --compartment-id $TENANCY_OCID --query "data[?\"description\"==\`$DOMAIN_DESCRIPTION\`].id | [0]" --raw-output)
AI_DOMAIN_ENDPOINT=""
AI_DOMAIN_ENDPOINT=$(oci iam domain list --compartment-id $TENANCY_OCID --query 'data[?"description"==\`$DOMAIN_DESCRIPTION\`].url | [0]' --raw-output)
AI_DOMAIN_NAME=$(oci iam domain list --compartment-id $TENANCY_OCID --query "data[?"description"==\`$DOMAIN_DESCRIPTION\`].[\"display-name\"] | [0] | [0]" --raw-output)
AI_GROUP_OCID=$(oci identity-domains groups list --endpoint $AI_DOMAIN_ENDPOINT  --query 'data.resources[?"display-name"==`'"$AI_GROUP_NAME"'`].id | [0]' --raw-output)


set +x # Print the retrieved information without the debug output

echo "OCI Tenancy OCID: " $TENANCY_OCID
echo "Region: " $REGION
echo "Compartment Name: " $COMPARTMENT_NAME
echo "Compartment OCID: " $COMPARTMENT_OCID
#echo "Availability Domains: " $AD1, $AD2, $AD3
echo "Default Domain OCID: " $DEFAULT_DOMAIN
echo "AI Domain OCID: " $AI_DOMAIN_OCID
echo "AI Domain Name: " $AI_DOMAIN_NAME
echo "AI Group OCID: " $AI_GROUP_OCID
echo "AI Group Name: " $AI_GROUP_NAME


echo "Completed listing Tenancy Information at $(date)"
