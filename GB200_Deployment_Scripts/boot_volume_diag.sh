#!/bin/bash
#===============================================================================
# get_instance_boot_volume.sh - Get boot volume details for an instance
# Usage: ./get_instance_boot_volume.sh <instance_ocid>
#===============================================================================

set -euo pipefail

# Source variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/variables.sh" ]]; then
    source "${SCRIPT_DIR}/variables.sh"
else
    echo "ERROR: variables.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

# Check for instance_id argument
INSTANCE_ID="${1:-}"
if [[ -z "$INSTANCE_ID" ]]; then
    echo "Usage: $0 <instance_ocid>"
    echo ""
    echo "Example: $0 ocid1.instance.oc1.us-phoenix-1.abcd1234..."
    exit 1
fi

echo "=============================================="
echo "Boot Volume Details for Instance"
echo "=============================================="
echo ""
echo "Instance ID: $INSTANCE_ID"
echo "Compartment: $COMPARTMENT_ID"
echo ""

# Get instance details (including AD)
echo "Fetching instance details..."
INSTANCE_JSON=$(oci compute instance get \
    --instance-id "$INSTANCE_ID" \
    --output json 2>/dev/null) || {
    echo "ERROR: Failed to get instance details"
    exit 1
}

INSTANCE_NAME=$(echo "$INSTANCE_JSON" | jq -r '.data["display-name"] // "N/A"')
AD=$(echo "$INSTANCE_JSON" | jq -r '.data["availability-domain"] // empty')
STATE=$(echo "$INSTANCE_JSON" | jq -r '.data["lifecycle-state"] // "N/A"')

echo "Instance Name: $INSTANCE_NAME"
echo "State:         $STATE"
echo "AD:            $AD"
echo ""

if [[ -z "$AD" ]]; then
    echo "ERROR: Could not determine availability domain"
    exit 1
fi

# Get boot volume attachment
echo "Fetching boot volume attachment..."
BV_ATTACH_JSON=$(oci compute boot-volume-attachment list \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AD" \
    --instance-id "$INSTANCE_ID" \
    --output json 2>/dev/null) || {
    echo "ERROR: Failed to get boot volume attachment"
    exit 1
}

echo ""
echo "--- Boot Volume Attachment Raw Response ---"
echo "$BV_ATTACH_JSON" | jq '.data[0] // "No attachment found"'
echo ""

BV_ID=$(echo "$BV_ATTACH_JSON" | jq -r '.data[0]["boot-volume-id"] // empty')

if [[ -z "$BV_ID" || "$BV_ID" == "null" ]]; then
    echo "ERROR: No boot volume attachment found"
    echo ""
    echo "Possible causes:"
    echo "  - Instance might be in a different compartment"
    echo "  - Boot volume might be detached"
    echo "  - Insufficient permissions"
    exit 1
fi

echo "Boot Volume ID: $BV_ID"
echo ""

# Get boot volume details
echo "Fetching boot volume details..."
BV_JSON=$(oci bv boot-volume get \
    --boot-volume-id "$BV_ID" \
    --output json 2>/dev/null) || {
    echo "ERROR: Failed to get boot volume details"
    exit 1
}

echo ""
echo "--- Boot Volume Raw Response ---"
echo "$BV_JSON" | jq '.data | {
    "display-name": .["display-name"],
    "size-in-gbs": .["size-in-gbs"],
    "vpus-per-gb": .["vpus-per-gb"],
    "lifecycle-state": .["lifecycle-state"],
    "id": .id
}'
echo ""

# Extract values
BV_NAME=$(echo "$BV_JSON" | jq -r '.data["display-name"] // "N/A"')
BV_SIZE=$(echo "$BV_JSON" | jq -r '.data["size-in-gbs"] // "N/A"')
BV_VPUS=$(echo "$BV_JSON" | jq -r '.data["vpus-per-gb"] // "N/A"')
BV_STATE=$(echo "$BV_JSON" | jq -r '.data["lifecycle-state"] // "N/A"')

echo "=============================================="
echo "SUMMARY"
echo "=============================================="
echo ""
echo "Instance:       $INSTANCE_NAME"
echo "Boot Volume:    $BV_NAME"
echo "Size (GB):      $BV_SIZE"
echo "VPUs per GB:    $BV_VPUS"
echo "BV State:       $BV_STATE"
echo ""

# Explain VPUs
case "$BV_VPUS" in
    10) echo "Performance Tier: Balanced (10 VPUs/GB)" ;;
    20) echo "Performance Tier: Higher Performance (20 VPUs/GB)" ;;
    30) echo "Performance Tier: Ultra High Performance (30 VPUs/GB)" ;;
    *) echo "Performance Tier: Custom ($BV_VPUS VPUs/GB)" ;;
esac