#!/bin/bash

INSTANCE_OCID=$1

echo "Sourcing Variables from variables.sh"

source ./variables.sh

echo "Showing console history for $1 in $REGION at $(date)"
CONSOLE_HISTORY_ID=$(oci --region $REGION compute console-history capture --instance-id $INSTANCE_OCID | jq -r '.data.id')
oci compute console-history get-content --instance-console-history-id $CONSOLE_HISTORY_ID --length 10000000 --file -