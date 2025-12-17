# Copyright (c) 2025 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

# Get all OCI services for the region
data "oci_core_services" "all_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

# Get the service OCID for the all services endpoint
# This is required for NSG rules with SERVICE_CIDR_BLOCK destination type
data "oci_core_services" "all_services_for_id" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

# ==============================================================================
# RANDOM STRING GENERATORS
# ==============================================================================
# Generate unique identifiers for resource naming and DNS labels

# Generate a unique 6-character state ID for resource naming
# This ensures unique resource names across multiple deployments
resource "random_string" "state_id" {
  length  = 6
  lower   = true
  numeric = false
  special = false
  upper   = false
}

# Generate a unique 6-character DNS label for VCN and subnets
# DNS labels must be alphanumeric only (no numbers in this case)
resource "random_string" "dns_label" {
  length  = 6
  special = false
  upper   = false
  numeric = false
}

# ==============================================================================
# LOCAL VARIABLES
# ==============================================================================
# Define computed values used throughout the configuration

locals {
  # Unique state identifier used for tagging and tracking resources
  state_id = random_string.state_id.result
  
  # VCN name with unique suffix (e.g., "oke-gpu-quickstart-abc12345")
  vcn_name = format("%v-%v", var.vcn_display_name, local.state_id)
  
  # Convert comma-separated CIDR string to list and trim whitespace
  vcn_cidrs = [for cidr in split(",", var.vcn_cidrs) : trimspace(cidr)]
  
  # Gateway creation flags
  create_internet_gateway = var.create_internet_gateway  # User-configurable via checkbox
  create_nat_gateway      = true                         # Always create NAT gateway for private subnets
  create_service_gateway  = true                         # Always create service gateway for OCI services
}

# ==============================================================================
# VIRTUAL CLOUD NETWORK (VCN)
# ==============================================================================
# Create the primary VCN using the official Oracle Terraform module
# This module handles VCN, gateways, route tables, and default security list

module "vcn" {
  source  = "oracle-terraform-modules/vcn/oci"
  version = "3.6.0"
  
  # Compartment for all network resources
  compartment_id = var.compartment_ocid

  # Apply tags for resource identification and tracking
  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "network",
    },
    var.tags
  )

  # Gateway configuration
  # Internet Gateway: For public subnet internet access
  # NAT Gateway: For private subnet outbound internet access
  # Service Gateway: For private access to OCI services
  create_internet_gateway = local.create_internet_gateway
  create_nat_gateway      = local.create_nat_gateway
  create_service_gateway  = local.create_service_gateway
  
  # Optional custom route rules for gateways
  internet_gateway_route_rules = var.internet_gateway_route_rules
  nat_gateway_route_rules      = var.nat_gateway_route_rules
  nat_gateway_public_ip_id     = var.nat_gateway_public_ip_id
  
  # Lock down default security list (we use NSGs instead)
  lockdown_default_seclist = var.lockdown_default_seclist
  
  # VCN configuration
  vcn_cidrs     = local.vcn_cidrs                                      # VCN CIDR blocks
  vcn_dns_label = var.assign_dns ? local.state_id : null  # Optional DNS label
  vcn_name      = local.vcn_name                                       # VCN display name
}

# ==============================================================================
# DYNAMIC ROUTING GATEWAY (DRG)
# ==============================================================================
# Optional DRG for hybrid cloud connectivity (VPN, FastConnect)
# Created only when var.create_drg = true

# Create DRG resource
resource "oci_core_drg" "drg" {
  count          = var.create_drg ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = format("%v-drg", local.vcn_name)
  
  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "network",
    },
    var.tags
  )
}

# Attach DRG to VCN for routing
resource "oci_core_drg_attachment" "drg_attachment" {
  count        = var.create_drg ? 1 : 0
  drg_id       = oci_core_drg.drg[0].id
  display_name = format("%v-drg-attachment", local.vcn_name)
  
  network_details {
    id   = module.vcn.vcn_id
    type = "VCN"
  }
  
  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "network",
    },
    var.tags
  )
}
