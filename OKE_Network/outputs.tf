# Copyright (c) 2025 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

# ==============================================================================
# STATE AND IDENTIFICATION OUTPUTS
# ==============================================================================

output "state_id" {
  description = "Unique state identifier for this deployment"
  value       = local.state_id
}

# ==============================================================================
# VCN OUTPUTS
# ==============================================================================

output "vcn_id" {
  description = "VCN OCID"
  value       = module.vcn.vcn_id
}

output "vcn_name" {
  description = "VCN name"
  value       = local.vcn_name
}

output "vcn_cidr_blocks" {
  description = "VCN CIDR blocks"
  value       = local.vcn_cidrs
}

# ==============================================================================
# GATEWAY OUTPUTS
# ==============================================================================

output "internet_gateway_id" {
  description = "Internet Gateway OCID"
  value       = module.vcn.internet_gateway_id
}

output "nat_gateway_id" {
  description = "NAT Gateway OCID"
  value       = module.vcn.nat_gateway_id
}

output "service_gateway_id" {
  description = "Service Gateway OCID"
  value       = module.vcn.service_gateway_id
}

output "drg_id" {
  description = "Dynamic Routing Gateway OCID"
  value       = var.create_drg ? oci_core_drg.drg[0].id : null
}

output "drg_attachment_id" {
  description = "DRG VCN Attachment OCID"
  value       = var.create_drg ? oci_core_drg_attachment.drg_attachment[0].id : null
}

# ==============================================================================
# ROUTE TABLE OUTPUTS
# ==============================================================================

output "ig_route_table_id" {
  description = "Internet Gateway route table OCID"
  value       = module.vcn.ig_route_id
}

output "nat_route_table_id" {
  description = "NAT Gateway route table OCID"
  value       = module.vcn.nat_route_id
}

output "vcn_all_attributes" {
  description = "All attributes of the VCN"
  value       = module.vcn.vcn_all_attributes
  sensitive   = true
}

# ==============================================================================
# SUBNET OUTPUTS
# ==============================================================================

output "bastion_subnet_id" {
  description = "OCID of bastion subnet"
  value       = var.create_bastion_subnet ? oci_core_subnet.bastion[0].id : null
}

output "operator_subnet_id" {
  description = "OCID of operator subnet"
  value       = var.create_operator_subnet ? oci_core_subnet.operator[0].id : null
}

output "int_lb_subnet_id" {
  description = "OCID of internal load balancer subnet"
  value       = oci_core_subnet.int_lb.id
}

output "pub_lb_subnet_id" {
  description = "OCID of public load balancer subnet"
  value       = var.create_public_subnets ? oci_core_subnet.pub_lb[0].id : null
}

output "cp_subnet_id" {
  description = "OCID of control plane subnet"
  value       = oci_core_subnet.cp.id
}

output "workers_subnet_id" {
  description = "OCID of workers subnet"
  value       = oci_core_subnet.workers.id
}

output "pods_subnet_id" {
  description = "OCID of pods subnet"
  value       = oci_core_subnet.pods.id
}

output "fss_subnet_id" {
  description = "OCID of FSS subnet"
  value       = var.create_fss_subnet ? oci_core_subnet.fss[0].id : null
}

output "lustre_subnet_id" {
  description = "OCID of Lustre subnet"
  value       = var.create_lustre_subnet ? oci_core_subnet.lustre[0].id : null
}

# ==============================================================================
# SUBNET CIDR BLOCK OUTPUTS
# ==============================================================================

output "bastion_subnet_cidr" {
  description = "CIDR block of bastion subnet"
  value       = var.create_bastion_subnet ? oci_core_subnet.bastion[0].cidr_block : null
}

output "operator_subnet_cidr" {
  description = "CIDR block of operator subnet"
  value       = var.create_operator_subnet ? oci_core_subnet.operator[0].cidr_block : null
}

output "int_lb_subnet_cidr" {
  description = "CIDR block of internal load balancer subnet"
  value       = oci_core_subnet.int_lb.cidr_block
}

output "pub_lb_subnet_cidr" {
  description = "CIDR block of public load balancer subnet"
  value       = var.create_public_subnets ? oci_core_subnet.pub_lb[0].cidr_block : null
}

output "cp_subnet_cidr" {
  description = "CIDR block of control plane subnet"
  value       = oci_core_subnet.cp.cidr_block
}

output "workers_subnet_cidr" {
  description = "CIDR block of workers subnet"
  value       = oci_core_subnet.workers.cidr_block
}

output "pods_subnet_cidr" {
  description = "CIDR block of pods subnet"
  value       = oci_core_subnet.pods.cidr_block
}

output "fss_subnet_cidr" {
  description = "CIDR block of FSS subnet"
  value       = var.create_fss_subnet ? oci_core_subnet.fss[0].cidr_block : null
}

output "lustre_subnet_cidr" {
  description = "CIDR block of Lustre subnet"
  value       = var.create_lustre_subnet ? oci_core_subnet.lustre[0].cidr_block : null
}

# ==============================================================================
# NETWORK SECURITY GROUP OUTPUTS
# ==============================================================================

output "bastion_nsg_id" {
  description = "OCID of bastion NSG"
  value       = var.create_bastion_subnet ? oci_core_network_security_group.bastion_nsg[0].id : null
}

output "operator_nsg_id" {
  description = "OCID of operator NSG"
  value       = var.create_operator_subnet ? oci_core_network_security_group.operator_nsg[0].id : null
}

output "int_lb_nsg_id" {
  description = "OCID of internal LB NSG"
  value       = oci_core_network_security_group.int_lb_nsg.id
}

output "pub_lb_nsg_id" {
  description = "OCID of public LB NSG"
  value       = var.create_public_subnets ? oci_core_network_security_group.pub_lb_nsg[0].id : null
}

output "cp_nsg_id" {
  description = "OCID of control plane NSG"
  value       = oci_core_network_security_group.cp_nsg.id
}

output "workers_nsg_id" {
  description = "OCID of workers NSG"
  value       = oci_core_network_security_group.workers_nsg.id
}

output "pods_nsg_id" {
  description = "OCID of pods NSG"
  value       = oci_core_network_security_group.pods_nsg.id
}

output "fss_nsg_id" {
  description = "OCID of FSS NSG"
  value       = var.create_fss_subnet ? oci_core_network_security_group.fss_nsg[0].id : null
}

# ==============================================================================
# IAM POLICY OUTPUTS
# ==============================================================================

output "dynamic_group_id" {
  description = "OCID of the dynamic group (if created)"
  value       = var.create_policies ? oci_identity_dynamic_group.vcn_quickstart[0].id : null
}

output "dynamic_group_name" {
  description = "Name of the dynamic group (if created)"
  value       = var.create_policies ? oci_identity_dynamic_group.vcn_quickstart[0].name : null
}

output "iam_policy_id" {
  description = "OCID of the IAM policy (if created)"
  value       = var.create_policies ? oci_identity_policy.vcn_quickstart[0].id : null
}

output "iam_policy_name" {
  description = "Name of the IAM policy (if created)"
  value       = var.create_policies ? oci_identity_policy.vcn_quickstart[0].name : null
}

# ==============================================================================
# COMPREHENSIVE NSG CONFIGURATION SUMMARY
# ==============================================================================
# This output provides a human-readable summary of all NSGs with their
# associated subnets and CIDR blocks for easy reference in Resource Manager
# Application Information page

output "nsg_configuration_summary" {
  description = "Summary of all Network Security Groups with their associated subnets and CIDR blocks"
  value = <<-EOT

==============================================
NETWORK SECURITY GROUP CONFIGURATION SUMMARY
==============================================

VCN: ${local.vcn_name}
VCN CIDR: ${join(", ", local.vcn_cidrs)}

----------------------------------------------
CONTROL PLANE NSG
----------------------------------------------
NSG ID: ${oci_core_network_security_group.cp_nsg.id}
Subnet: ${local.cp_name}
CIDR: ${oci_core_subnet.cp.cidr_block}
Type: ${var.control_plane_is_public ? "Public" : "Private"}

----------------------------------------------
WORKERS NSG
----------------------------------------------
NSG ID: ${oci_core_network_security_group.workers_nsg.id}
Subnet: ${local.workers_name}
CIDR: ${oci_core_subnet.workers.cidr_block}
Type: Private

----------------------------------------------
PODS NSG
----------------------------------------------
NSG ID: ${oci_core_network_security_group.pods_nsg.id}
Subnet: ${local.pods_name}
CIDR: ${oci_core_subnet.pods.cidr_block}
Type: Private

----------------------------------------------
INTERNAL LOAD BALANCER NSG
----------------------------------------------
NSG ID: ${oci_core_network_security_group.int_lb_nsg.id}
Subnet: ${local.int_lb_name}
CIDR: ${oci_core_subnet.int_lb.cidr_block}
Type: Private

%{if var.create_public_subnets~}
----------------------------------------------
PUBLIC LOAD BALANCER NSG
----------------------------------------------
NSG ID: ${oci_core_network_security_group.pub_lb_nsg[0].id}
Subnet: ${local.pub_lb_name}
CIDR: ${oci_core_subnet.pub_lb[0].cidr_block}
Type: Public

%{endif~}
%{if var.create_bastion_subnet~}
----------------------------------------------
BASTION NSG
----------------------------------------------
NSG ID: ${oci_core_network_security_group.bastion_nsg[0].id}
Subnet: ${local.bastion_name}
CIDR: ${oci_core_subnet.bastion[0].cidr_block}
Type: Public

%{endif~}
%{if var.create_operator_subnet~}
----------------------------------------------
OPERATOR NSG
----------------------------------------------
NSG ID: ${oci_core_network_security_group.operator_nsg[0].id}
Subnet: ${local.operator_name}
CIDR: ${oci_core_subnet.operator[0].cidr_block}
Type: Private

%{endif~}
%{if var.create_fss_subnet~}
----------------------------------------------
FILE STORAGE SERVICE (FSS) NSG
----------------------------------------------
NSG ID: ${oci_core_network_security_group.fss_nsg[0].id}
Subnet: ${local.fss_name}
CIDR: ${oci_core_subnet.fss[0].cidr_block}
Type: Private

%{endif~}
==============================================

EOT
}
