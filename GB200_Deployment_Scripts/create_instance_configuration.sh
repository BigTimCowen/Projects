#!/usr/bin/env bash
set -euo pipefail
LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Starting creation of instance configuration at $(date)"
echo "Sourcing Variables from variables.sh"
source ./variables.sh

# -----------------------------
# Encode cloud-init
# -----------------------------
echo "Encoding cloud-init.yml"
BASE64_ENCODED_CLOUD_INIT=$(base64 -w 0 cloud-init.yml)

# -----------------------------
# Create Instance Configuration
# -----------------------------
echo "Creating Instance Configuration"
oci --region "${REGION}" \
  compute-management instance-configuration create \
  --compartment-id "${COMPARTMENT_ID}" \
  --display-name gb200-oke \
  --instance-details "$(cat <<EOF
{
  "instanceType": "compute",
  "launchDetails": {
    "availabilityDomain": "${AD}",
    "compartmentId": "${COMPARTMENT_ID}",
    "createVnicDetails": {
      "assignIpv6Ip": false,
      "assignPublicIp": false,
      "assignPrivateDnsRecord": true,
      "subnetId": "${WORKER_SUBNET_ID}",
      "nsgIds": [
        "${WORKER_SUBNET_NSG_ID}"
      ]
    },
    "metadata": {
      "user_data": "${BASE64_ENCODED_CLOUD_INIT}",
      "oke-native-pod-networking": "true",
      "oke-max-pods": "60",
      "pod-subnets": "${POD_SUBNET_ID}",
      "pod-nsgids": "${POD_SUBNET_NSG_ID}"
    },
    "shape": "BM.GPU.B200.8",
    "sourceDetails": {
      "bootVolumeSizeInGBs": "512",
      "bootVolumeVpusPerGB": "20",
      "sourceType": "image",
      "imageId": "${IMAGE_ID}"
    },
    "agentConfig": {
      "isMonitoringDisabled": false,
      "isManagementDisabled": false,
      "pluginsConfig": [
        { "name": "WebLogic Management Service", "desiredState": "DISABLED" },
        { "name": "Vulnerability Scanning", "desiredState": "DISABLED" },
        { "name": "Oracle Java Management Service", "desiredState": "DISABLED" },
        { "name": "Oracle Autonomous Linux", "desiredState": "DISABLED" },
        { "name": "OS Management Service Agent", "desiredState": "DISABLED" },
        { "name": "OS Management Hub Agent", "desiredState": "DISABLED" },
        { "name": "Management Agent", "desiredState": "DISABLED" },
        { "name": "Custom Logs Monitoring", "desiredState": "ENABLED" },
        { "name": "Compute RDMA GPU Monitoring", "desiredState": "ENABLED" },
        { "name": "Compute Instance Run Command", "desiredState": "ENABLED" },
        { "name": "Compute Instance Monitoring", "desiredState": "ENABLED" },
        { "name": "Compute HPC RDMA Auto-Configuration", "desiredState": "ENABLED" },
        { "name": "Compute HPC RDMA Authentication", "desiredState": "ENABLED" },
        { "name": "Cloud Guard Workload Protection", "desiredState": "DISABLED" },
        { "name": "Block Volume Management", "desiredState": "DISABLED" },
        { "name": "Bastion", "desiredState": "DISABLED" }
      ]
    },
    "isPvEncryptionInTransitEnabled": false,
    "instanceOptions": {
      "areLegacyImdsEndpointsDisabled": false
    },
    "availabilityConfig": {
      "recoveryAction": "RESTORE_INSTANCE"
    }
  }
}
EOF
)"
echo "Instance Configuration ended at $(date)"