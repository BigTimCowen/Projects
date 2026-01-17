#!/bin/bash
# This script lists the Compute Capacity Topology.
# Requires policy compute-capacity-topology
LOGFILE="capacity_topology_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Listing capacity topology at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh

CAP_TOP_ID=$(oci compute capacity-topology list --compartment-id $TENANCY_ID --query 'data.items[]."id" | [0]' --raw-output)

echo "This is refreshed every 15 minutes based on capacity topology"
set -x
oci compute capacity-topology network-block list --capacity-topology-id $CAP_TOP_ID
set +x

echo "Completed listing capacity topology at $(date)"
