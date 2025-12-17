# Copyright (c) 2025 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

# ==============================================================================
# NETWORK SECURITY GROUP RULES
# ==============================================================================
# This file defines all security rules for NSGs in the OKE cluster
#
# RULE NAMING CONVENTION:
# {source_nsg}_to_{dest_nsg}_{protocol}_{port}     - For egress rules
# {source_nsg}_from_{source_nsg}_{protocol}_{port} - For ingress rules
#
# KEY OKE TRAFFIC FLOWS:
# 1. Control Plane (port 6443):
#    - Workers -> Control Plane (kubectl, API calls)
#    - Pods -> Control Plane (in-cluster API access)
#    - Control Plane -> Control Plane (HA control plane)
#
# 2. Kubelet (port 10250):
#    - Control Plane -> Workers (health checks, exec, logs)
#
# 3. Worker-to-Worker:
#    - All protocols for pod networking
#    - NodePort range: 30000-32767
#
# 4. Pod Networking:
#    - Pod-to-Pod: All protocols within pods NSG
#    - Pod-to-Worker: Access to NodePort and host services
#    - Pod-to-Services: Access to cluster services
#
# 5. Load Balancers:
#    - Public LB -> Workers (health checks and backend traffic)
#    - Internal LB -> Workers (health checks and backend traffic)
#    - Workers -> Load Balancers (return traffic)
#
# 6. ICMP:
#    - Type 3, Code 4 for path MTU discovery (required for OKE)
#
# PROTOCOL NUMBERS:
# - 1  = ICMP
# - 6  = TCP
# - 17 = UDP
# - all = All protocols
#
# ==============================================================================
module "nsg_rules" {
  source = "./nsg_rules/"
}

# Local variables for NSG IDs
locals {
  bastion_nsg_id  = var.create_bastion_subnet ? oci_core_network_security_group.bastion_nsg[0].id : null
  operator_nsg_id = var.create_operator_subnet ? oci_core_network_security_group.operator_nsg[0].id : null
  int_lb_nsg_id   = oci_core_network_security_group.int_lb_nsg.id
  pub_lb_nsg_id   = var.create_public_subnets ? oci_core_network_security_group.pub_lb_nsg[0].id : null
  cp_nsg_id       = oci_core_network_security_group.cp_nsg.id
  workers_nsg_id  = oci_core_network_security_group.workers_nsg.id
  pods_nsg_id     = oci_core_network_security_group.pods_nsg.id
  fss_nsg_id      = var.create_fss_subnet ? oci_core_network_security_group.fss_nsg[0].id : null

  # OCI Services CIDR - use cidr_block for NSG rules with SERVICE_CIDR_BLOCK type
  all_oci_services = data.oci_core_services.all_services.services[0].cidr_block
}








