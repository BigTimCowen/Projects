# Script to create Compute Cluster

source ./variables.sh


oci compute compute-cluster list --availability-domain $AD --compartment-id $COMPARTMENT_ID
