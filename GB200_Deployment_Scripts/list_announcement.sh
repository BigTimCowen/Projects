#!/bin/bash
# Script to list announcements from Oracle Cloud Infrastructure Announcements service
# Usage: ./list_announcement.sh [announcement_id]
# If announcement_id is provided, details for that specific announcement will be shown
# If no announcement_id is provided, all announcements will be listed

echo "Listing Announcements at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh

ANNOUNCEMENT_ID="$1"


if [ -z "$ANNOUNCEMENT_ID" ]; then
    # No announcement ID provided, list all announcements
    oci announce announcements list --compartment-id $COMPARTMENT_ID
else
    # Announcement ID provided, search for it in the list and get details
    echo "Searching for announcement: $ANNOUNCEMENT_ID"
    echo "---"

    # Search the list for the specific announcement
    oci announce announcements list \
        --compartment-id $COMPARTMENT_ID \
        --query "data.items[?id=='$ANNOUNCEMENT_ID']"

    echo ""
    echo "---"
    echo "Full announcement details:"
    echo "---"

    # Get full details of the specific announcement
    oci announce announcements get --announcement-id $ANNOUNCEMENT_ID

    oci announce user-status get --announcement-id $ANNOUNCEMENT_ID
fi
