#!/bin/bash
# This script lists the Compute Capacity Topology.
# Requires policy compute-capacity-topology
LOGFILE="capacity_topology_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Listing capacity topology at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh
echo "This is refreshed every 15 minutes based on capacity topology"
set -x
oci compute capacity-topology list --compartment-id $TENANCY_ID
set +x

echo "Completed listing capacity topology at $(date)"
