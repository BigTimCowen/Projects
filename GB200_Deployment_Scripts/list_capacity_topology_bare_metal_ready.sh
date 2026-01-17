#!/bin/bash
# This script lists the Compute Capacity Topology for instances in tenancy.
# Requires policy compute-capacity-topology
# Usage: ./list_capacity_topology_bare_metal_ready.sh [LIFECYCLE_STATE]
# LIFECYCLE_STATE is optional. If not provided, shows ALL states without filtering.
# Valid values: ACTIVE, INACTIVE, DELETED, CREATING, UPDATING, DELETING

LOGFILE="capacity_topology_oci_output.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "Listing capacity topology at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh

CAP_TOP_ID=$(oci compute capacity-topology list --compartment-id "$TENANCY_ID" --query 'data.items[]."id" | [0]' --raw-output)

if [ -z "$CAP_TOP_ID" ]; then
    echo "ERROR: No capacity topology found in tenancy"
    exit 1
fi

LIFECYCLE_STATE="${1}"

echo "Capacity Topology ID: $CAP_TOP_ID"
if [ -z "$LIFECYCLE_STATE" ]; then
    echo "Showing ALL lifecycle states (no filter applied)"
else
    echo "Filtering by Lifecycle State: $LIFECYCLE_STATE"
fi
echo "This is refreshed every 15 minutes based on capacity topology"
echo ""

set -x
if [ -z "$LIFECYCLE_STATE" ]; then
    # No filter - show all states without --query
    oci compute capacity-topology bare-metal-host list \
        --capacity-topology-id "$CAP_TOP_ID" \
        --query "data.items[*].{baremetalid:id,InstanceID:\"instance-id\",InstanceShape:\"instance-shape\",State:\"lifecycle-state\"}" \
        --output table

else
    # Filter by specific state using --query
    oci compute capacity-topology bare-metal-host list \
        --capacity-topology-id "$CAP_TOP_ID" \
        --query "data.items[?\"lifecycle-state\"==\`$LIFECYCLE_STATE\`].{baremetalid:id,InstanceID:\"instance-id\",InstanceShape:\"instance-shape\",State:\"lifecycle-state\"}" \
        --output table
fi
set +x

echo ""
echo "Completed listing capacity topology at $(date)"
