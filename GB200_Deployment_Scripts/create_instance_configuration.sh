#!/bin/bash
# This script creates an instance configuration for the GB200 OKE deployment. It uses the OCI CLI to create an instance configuration with the specified parameters and cloud-init.yml configuration.  
# The cloud-init.yml is what is used to configure the instance at launch time, and it is encoded in base64 format before being passed to the OCI CLI command.  This cloud-init.yml bootstraps the instance to the OKE CP.
# Feel free to modify:
# display-name, boot volumesizeinGBs

set -euo pipefail
LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Starting creation of instance configuration at $(date)"
echo "Sourcing Variables from variables.sh"
source ./variables.sh
echo "Region: ${REGION}"
echo "Compartment OCID: ${COMPARTMENT_ID}"
echo "Availability Domain: ${AD}"
echo "Worker Subnet OCID: ${WORKER_SUBNET_ID}"
echo "Worker Subnet NSG OCID: ${WORKER_SUBNET_NSG_ID}"
echo "POD Subnet OCID: ${POD_SUBNET_ID}"
echo "POD Subnet NSG OCID: ${POD_SUBNET_NSG_ID}"
echo "Image OCID: ${IMAGE_ID}"
echo "Shape Name: ${SHAPE_NAME}"
echo "Instance Configuration Name: ${INSTANCE_CONFIG_NAME}"

# -----------------------------
# Encode cloud-init
# -----------------------------
echo "Encoding cloud-init.yml"
BASE64_ENCODED_CLOUD_INIT=$(base64 -w 0 cloud-init.yml)

# -----------------------------
# Create Instance Configuration
# -----------------------------
echo "Creating Instance Configuration"
set -x
oci --region "${REGION}" \
  compute-management instance-configuration create \
  --compartment-id "${COMPARTMENT_ID}" \
  --display-name "${INSTANCE_CONFIG_NAME} \
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
    "shape": "${SHAPE_NAME}",
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

set +x 

echo "Instance Configuration ended at $(date)"