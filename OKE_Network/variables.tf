# Copyright (c) 2025 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

# ==============================================================================
# REQUIRED VARIABLES - OCI IDENTITY
# ==============================================================================
# These variables are typically injected by OCI Resource Manager

variable "compartment_ocid" {
  type        = string
  description = "The compartment OCID where the VCN will be created"
}

variable "tenancy_ocid" {
  type        = string
  description = "The tenancy OCID"
}

variable "region" {
  type        = string
  description = "The OCI region where resources will be created"
}

variable "home_region" {
  type        = string
  default     = null
  description = "The home region for the tenancy"
}

# ==============================================================================
# VCN CONFIGURATION
# ==============================================================================

variable "create_vcn" {
  type        = bool
  default     = true
  description = "Whether to create VCN"
}

variable "vcn_display_name" {
  type        = string
  default     = "oke-gpu-quickstart"
  description = "Name of the VCN to create"
}

variable "vcn_cidrs" {
  type        = string
  default     = "10.140.0.0/16"
  description = "CIDR blocks for the VCN"
}

# ==============================================================================
# GATEWAY CONFIGURATION
# ==============================================================================

variable "create_public_subnets" {
  type        = bool
  default     = true
  description = "Whether to create public subnets and internet gateway"
}

variable "create_internet_gateway" {
  type        = bool
  default     = true
  description = "Whether to create an Internet Gateway for public subnet connectivity"
}

variable "create_drg" {
  type        = bool
  default     = false
  description = "Whether to create a Dynamic Routing Gateway for hybrid cloud connectivity"
}

# ==============================================================================
# SUBNET CONFIGURATION
# ==============================================================================

# Subnet Advanced Settings Toggle
variable "subnets_advanced_settings" {
  type        = bool
  default     = false
  description = "Show advanced subnet CIDR configuration options"
}

# Optional Subnet Creation Flags
variable "create_bastion_subnet" {
  type        = bool
  default     = true
  description = "Whether to create bastion subnet"
}

variable "create_operator_subnet" {
  type        = bool
  default     = true
  description = "Whether to create operator subnet"
}

variable "create_fss_subnet" {
  type        = bool
  default     = true
  description = "Whether to create file storage subnet"
}

variable "create_lustre_subnet" {
  type        = bool
  default     = false
  description = "Whether to create lustre storage subnet"
}

# ==============================================================================
# ADVANCED SUBNET CIDR CONFIGURATION
# ==============================================================================
# These variables allow custom CIDR blocks for each subnet
# If not provided, CIDRs are auto-calculated from the VCN CIDR

variable "bastion_subnet_cidr" {
  type        = string
  default     = "10.140.0.0/29"
  description = "Optional custom CIDR for bastion subnet"
}

variable "operator_subnet_cidr" {
  type        = string
  default     = "10.140.0.96/29"
  description = "Optional custom CIDR for operator subnet"
}

variable "int_lb_subnet_cidr" {
  type        = string
  default     = "10.140.0.64/27"
  description = "Optional custom CIDR for internal LB subnet"
}

variable "pub_lb_subnet_cidr" {
  type        = string
  default     = "10.140.32.0/27"
  description = "Optional custom CIDR for public LB subnet"
}

variable "cp_subnet_cidr" {
  type        = string
  default     = "10.140.0.8/29"
  description = "Optional custom CIDR for control plane subnet"
}

variable "workers_subnet_cidr" {
  type        = string
  default     = "10.140.48.0/20"
  description = "Optional custom CIDR for workers subnet"
}

variable "pods_subnet_cidr" {
  type        = string
  default     = "10.140.16.0/20"
  description = "Optional custom CIDR for pods subnet"
}

variable "fss_subnet_cidr" {
  type        = string
  default     = "10.140.0.32/27"
  description = "Optional custom CIDR for FSS subnet"
}

variable "lustre_subnet_cidr" {
  type        = string
  default     = "10.140.0.64/27"
  description = "Optional custom CIDR for Lustre subnet"
}

# ==============================================================================
# SUBNET DISPLAY NAME CONFIGURATION
# ==============================================================================
# Custom display names for each subnet
# If not provided, defaults will be used: "{subnet_type}-{state_id}"

variable "bastion_subnet_name" {
  type        = string
  default     = "bastion"
  description = "Custom display name for bastion subnet (default: bastion-{state_id})"
}

variable "operator_subnet_name" {
  type        = string
  default     = "operator"
  description = "Custom display name for operator subnet (default: operator-{state_id})"
}

variable "int_lb_subnet_name" {
  type        = string
  default     = "int_lb"
  description = "Custom display name for internal LB subnet (default: int_lb-{state_id})"
}

variable "pub_lb_subnet_name" {
  type        = string
  default     = "pub_lb"
  description = "Custom display name for public LB subnet (default: pub_lb-{state_id})"
}

variable "cp_subnet_name" {
  type        = string
  default     = "cp"
  description = "Custom display name for control plane subnet (default: cp-{state_id})"
}

variable "workers_subnet_name" {
  type        = string
  default     = "workers"
  description = "Custom display name for workers subnet (default: workers-{state_id})"
}

variable "pods_subnet_name" {
  type        = string
  default     = "pods"
  description = "Custom display name for pods subnet (default: pods-{state_id})"
}

variable "fss_subnet_name" {
  type        = string
  default     = "fss"
  description = "Custom display name for FSS subnet (default: fss-{state_id})"
}

variable "lustre_subnet_name" {
  type        = string
  default     = "lustre"
  description = "Custom display name for Lustre subnet (default: lustre-{state_id})"
}

# ==============================================================================
# DNS AND SECURITY CONFIGURATION
# ==============================================================================

variable "assign_dns" {
  type        = bool
  default     = true
  description = "Assign DNS labels to VCN and subnets"
}

variable "lockdown_default_seclist" {
  type        = bool
  default     = true
  description = "Remove all default security list rules"
}

# ==============================================================================
# ADVANCED GATEWAY CONFIGURATION
# ==============================================================================

variable "internet_gateway_route_rules" {
  type        = list(map(string))
  default     = null
  description = "Additional internet gateway route rules"
}

variable "nat_gateway_route_rules" {
  type        = list(map(string))
  default     = null
  description = "Additional NAT gateway route rules"
}

variable "nat_gateway_public_ip_id" {
  type        = string
  default     = null
  description = "OCID of reserved public IP for NAT gateway"
}

# ==============================================================================
# RESOURCE TAGGING
# ==============================================================================

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Freeform tags to apply to all resources"
}

# ==============================================================================
# CONTROL PLANE CONFIGURATION
# ==============================================================================

variable "control_plane_is_public" {
  type        = bool
  default     = true
  description = "Whether to create control plane subnet as public"
}

# ==============================================================================
# IAM POLICY CONFIGURATION
# ==============================================================================

variable "create_policies" {
  type        = bool
  default     = false
  description = "Create dynamic group and policies for OKE cluster self-managed nodes"
}
