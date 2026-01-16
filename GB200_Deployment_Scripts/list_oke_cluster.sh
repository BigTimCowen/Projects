#!/bin/bash
# This script lists the OKE Cluster details in the specified compartment and region.
# It sources the variables from the variables.sh file and uses the OCI CLI to retrieve the necessary information.
# It expects the following variables to be defined in the variables.sh file:
# - REGION: The OCI region where the OKE cluster is deployed.
# - COMPARTMENT_NAME: The name of the compartment where the OKE cluster is deployed.
# - CLUSTER_NAME: The name of the OKE cluster to search for to provide the OCID.

LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Listing OKE Cluster at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh

set -x
TENANCY_OCID=`curl -sH "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/ | jq -r .tenantId`
COMPARTMENT_OCID=$(oci iam compartment list --compartment-id $TENANCY_OCID  --compartment-id-in-subtree true  --all |  jq -r --arg name "$COMPARTMENT_NAME" '.data[] | select(.name | contains($name)) | .id')
PRIMARY_CLUSTER_NAME=$(oci ce cluster list --compartment-id $COMPARTMENT_OCID   --query "data[?\"lifecycle-state\"==\`ACTIVE\` && contains(name, \`$CLUSTER_NAME\`)].\"name\" | [0]" --raw-output)
PRIMARY_OKE_OCID=$(oci ce cluster list --compartment-id $COMPARTMENT_OCID   --query "data[?\"lifecycle-state\"==\`ACTIVE\` && contains(name, \`$CLUSTER_NAME\`)].\"id\" | [0]" --raw-output)
PRIMARY_OKE_VCN=$(oci ce cluster list --compartment-id $COMPARTMENT_OCID   --query "data[?\"lifecycle-state\"==\`ACTIVE\` && contains(name, \`$CLUSTER_NAME\`)].\"vcn-id\" | [0]" --raw-output)
PRIMARY_OKE_VCN_NAME=$(oci network vcn list --compartment-id $COMPARTMENT_OCID --query "data[?\"id\"==\`$PRIMARY_OKE_VCN\`].\"display-name\" | [0]" --raw-output)
CLUSTER_POD_NETWORK_OPTION=$(oci ce cluster list --compartment-id $COMPARTMENT_OCID   --query "data[?\"lifecycle-state\"==\`ACTIVE\` && contains(name, \`$CLUSTER_NAME\`)].\"cluster-pod-network-options\" | [0]" --raw-output)
WORKER_VCN=$(oci network subnet list --vcn-id $PRIMARY_OKE_VCN --compartment-id $COMPARTMENT_OCID --query 'data[?contains("display-name", `workers`)].id | [0]' --raw-output)
WORKER_VCN_NAME=$(oci network subnet list --vcn-id $PRIMARY_OKE_VCN --compartment-id $COMPARTMENT_OCID --query 'data[?contains("display-name", `workers`)]."display-name" | [0]' --raw-output)
WORKER_NSG_OCID=$(oci network nsg list --compartment-id $COMPARTMENT_OCID --query 'data[?contains("display-name", `workers`)].id | [0]' --raw-output)
WORKER_NSG_NAME=$(oci network nsg list --compartment-id $COMPARTMENT_OCID --query 'data[?contains("display-name", `workers`)]."display-name" | [0]' --raw-output)
POD_VCN=$(oci network subnet list --vcn-id $PRIMARY_OKE_VCN --compartment-id $COMPARTMENT_OCID --query 'data[?contains("display-name", `pods`)].id | [0]' --raw-output)
POD_VCN_NAME=$(oci network subnet list --vcn-id $PRIMARY_OKE_VCN --compartment-id $COMPARTMENT_OCID --query 'data[?contains("display-name", `pods`)]."display-name" | [0]' --raw-output)
POD_NSG_OCID=$(oci network nsg list --compartment-id $COMPARTMENT_OCID --query 'data[?contains("display-name", `pods`)].id | [0]' --raw-output)
POD_NSG_NAME=$(oci network nsg list --compartment-id $COMPARTMENT_OCID --query 'data[?contains("display-name", `pods`)]."display-name" | [0]' --raw-output)
AD1=$(oci iam availability-domain list --compartment-id $COMPARTMENT_OCID --query 'data[0].name' --region $REGION --raw-output)
AD2=$(oci iam availability-domain list --compartment-id $COMPARTMENT_OCID --query 'data[1].name' --region $REGION --raw-output)
AD3=$(oci iam availability-domain list --compartment-id $COMPARTMENT_OCID --query 'data[2].name' --region $REGION --raw-output)
COMPUTE_CLUSTER=$(oci compute compute-cluster list --availability-domain $AD --compartment-id $COMPARTMENT_ID --region $REGION --query 'data.items[?contains("display-name", `'"$COMPUTE_CLUSTER_DISPLAY_NAME"'`)].id | [0]' --raw-output)
IC_CC=$(oci --region $REGION compute-management instance-configuration list --compartment-id $COMPARTMENT_ID --query 'data[?contains("display-name", `'"$INSTANCE_CONFIG_DISPLAY_NAME"'`)].id | [0]' --raw-output)
set +x

echo "OCI Tenancy OCID: " $TENANCY_OCID
echo "Region: " $REGION
echo "Compartment Name: " $COMPARTMENT_NAME
echo "Compartment OCID: " $COMPARTMENT_OCID
echo "Availability Domains: " $AD1, $AD2, $AD3
echo "OKE Cluster Name: " $PRIMARY_CLUSTER_NAME
echo "OKE Cluster POD Network Option: " $CLUSTER_POD_NETWORK_OPTION
echo "OKE OCID: " $PRIMARY_OKE_OCID
echo "OKE VCN OCID: " $PRIMARY_OKE_VCN
echo "OKE VCN Name: " $PRIMARY_OKE_VCN_NAME
echo "OKE Worker Subnet: " $WORKER_VCN
echo "OKE Worker Subnet Name: " $WORKER_VCN_NAME
echo "OKE Worker Subnet NSG OCID: " $WORKER_NSG_OCID
echo "OKE Worker Subnet NSG Name:  " $WORKER_NSG_NAME
echo "OKE PODs Subnet: " $POD_VCN
echo "OKE PODs Subnet Name: " $POD_VCN_NAME
echo "OKE PODs Subnet NSG OCID: " $POD_NSG_OCID
echo "OKE PODs Subnet NSG Name: " $POD_NSG_NAME
echo "Compute Cluster OCID: " $COMPUTE_CLUSTER
echo "Instance Configuration OCID: " $IC_CC

echo "Completed listing OKE Clusters at $(date)"
