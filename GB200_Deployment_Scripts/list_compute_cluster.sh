#!/bin/bash
# This script lists the compute clusters in the specified compartment and availability domain.

source ./variables.sh

set -x
oci compute compute-cluster list --availability-domain $AD --compartment-id $COMPARTMENT_ID --region $REGION
set +x