#!/bin/bash
# This script creates a domain in OCI Identity and Access Management (IAM) using the OCI CLI.
# This is used separately to manage federation if needed and to provide a different domain vs the default.
#

LOGFILE="create_domain_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Creating domain in $TENANCY_ID at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh

echo "Creating domain with name $DOMAIN_NAME in compartment $TENANCY_ID at $(date)"
set -x 
oci iam domain create --compartment-id $$TENANCY_ID --name $DOMAIN_NAME --description $DOMAIN_DESCRIPTION --license-type "free" --wait-for-state "ACTIVE" --max-wait-seconds 300
set +x 

echo "Completed Domain $DOMAIN_NAME create at $(date)"