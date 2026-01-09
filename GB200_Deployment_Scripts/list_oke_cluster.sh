LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Listing OKE Cluster at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh

TENANCY_OCID=`curl -sH "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/ | jq -r .tenantId`
COMPARTMENT_OCID=$(oci iam compartment list --compartment-id $TENANCY_OCID  --compartment-id-in-subtree true  --all |  jq -r --arg name "$COMPARTMENT_NAME" '.data[] | select(.name | contains($name)) | .id')
PRIMARY_CLUSTER_NAME=$(oci ce cluster list --compartment-id $COMPARTMENT_OCID   --query "data[?\"lifecycle-state\"==\`ACTIVE\` && contains(name, \`$CLUSTER_NAME\`)].\"name\" | [0]" --raw-output)
PRIMARY_OKE_OCID=$(oci ce cluster list --compartment-id $COMPARTMENT_OCID   --query "data[?\"lifecycle-state\"==\`ACTIVE\` && contains(name, \`$CLUSTER_NAME\`)].\"id\" | [0]" --raw-output)
PRIMARY_OKE_VCN=$(oci ce cluster list --compartment-id $COMPARTMENT_OCID   --query "data[?\"lifecycle-state\"==\`ACTIVE\` && contains(name, \`$CLUSTER_NAME\`)].\"vcn-id\" | [0]" --raw-output)
WORKER_VCN=$(oci network subnet list --vcn-id $PRIMARY_OKE_VCN --compartment-id $COMPARTMENT_OCID --query 'data[?contains("display-name", `workers`)].id | [0]' --raw-output)
WORKER_NSG_OCID=$(oci network nsg list --compartment-id $COMPARTMENT_OCID --query 'data[?contains("display-name", `workers`)].id | [0]' --raw-output)
POD_VCN=$(oci network subnet list --vcn-id $PRIMARY_OKE_VCN --compartment-id $COMPARTMENT_OCID --query 'data[?contains("display-name", `pods`)].id | [0]' --raw-output)
POD_NSG_OCID=$(oci network nsg list --compartment-id $COMPARTMENT_OCID --query 'data[?contains("display-name", `pods`)].id | [0]' --raw-output)
AD1=$(oci iam availability-domain list --compartment-id $COMPARTMENT_OCID --query 'data[0].name' --region $REGION --raw-output)
AD2=$(oci iam availability-domain list --compartment-id $COMPARTMENT_OCID --query 'data[1].name' --region $REGION --raw-output)
AD3=$(oci iam availability-domain list --compartment-id $COMPARTMENT_OCID --query 'data[2].name' --region $REGION --raw-output)

echo "OCI Tenancy OCID: " $TENANCY_OCID
echo "Region: " $REGION
echo "Compartment Name: " $COMPARTMENT_NAME
echo "Compartment OCID: " $COMPARTMENT_OCID
echo "Availability Domains: " $AD1, $AD2, $AD3
echo "OKE Cluster Name: " $PRIMARY_CLUSTER_NAME
echo "OKE OCID: " $PRIMARY_OKE_OCID
echo "OKE VCN OCID: " $PRIMARY_OKE_VCN
echo "OKE Worker VCN: " $WORKER_VCN
echo "OKE Worker NSG OCID: " $WORKER_NSG_OCID
echo "OKE PODs VCN: " $POD_VCN
echo "OKE PODs NSG OCID: " $POD_NSG_OCID

echo "Completed listing OKE Clusters at $(date)"
