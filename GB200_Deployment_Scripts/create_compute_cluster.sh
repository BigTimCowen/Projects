# Script to create Compute Cluster

source ./variables.sh
DISPLAY_NAME="Tim-Test-Compute-Cluster"


oci compute compute-cluster create --availability-domain $AD --compartment-id $COMPARTMENT_ID --display-name $DISPLAY_NAME
