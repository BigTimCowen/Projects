# Copyright (c) 2025 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

# ==============================================================================
# NETWORK SECURITY GROUPS (NSGs)
# ==============================================================================
# NSGs provide stateful, granular security controls for OKE components
# Each NSG is assigned to specific resources and defines allowed traffic flows
# NSG rules are defined in nsg_rules.tf

# ==============================================================================
# BASTION NSG (OPTIONAL)
# ==============================================================================
# Applied to: Bastion host instances
# Purpose: Control SSH access to bastion and outbound connections
# Created: Only when create_bastion_subnet = true

resource "oci_core_network_security_group" "bastion_nsg" {
  count = var.create_bastion_subnet ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  display_name   = format("bastion-%s", local.state_id)

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "bastion"
    },
    var.tags
  )
}

# ==============================================================================
# OPERATOR NSG (OPTIONAL)
# ==============================================================================
# Applied to: Operator/admin instances, CI/CD runners
# Purpose: Control access for cluster administration and automation
# Created: Only when create_operator_subnet = true

resource "oci_core_network_security_group" "operator_nsg" {
  count = var.create_operator_subnet ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  display_name   = format("operator-%s", local.state_id)

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "operator"
    },
    var.tags
  )
}

# ==============================================================================
# INTERNAL LOAD BALANCER NSG (REQUIRED)
# ==============================================================================
# Applied to: Private OCI Load Balancers
# Purpose: Control traffic to/from internal load balancers serving cluster services
# Created: Always

resource "oci_core_network_security_group" "int_lb_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  display_name   = format("int_lb-%s", local.state_id)

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "int_lb"
    },
    var.tags
  )
}

# ==============================================================================
# PUBLIC LOAD BALANCER NSG (OPTIONAL)
# ==============================================================================
# Applied to: Public OCI Load Balancers
# Purpose: Control internet traffic to/from public load balancers
# Created: Only when create_public_subnets = true

resource "oci_core_network_security_group" "pub_lb_nsg" {
  count = var.create_public_subnets ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  display_name   = format("pub_lb-%s", local.state_id)

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "pub_lb"
    },
    var.tags
  )
}

# ==============================================================================
# CONTROL PLANE NSG (REQUIRED)
# ==============================================================================
# Applied to: OKE control plane endpoint
# Purpose: Control access to Kubernetes API server (port 6443)
# Created: Always
# Key traffic: API calls from workers, pods, and authorized users

resource "oci_core_network_security_group" "cp_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  display_name   = format("cp-%s", local.state_id)

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "control_plane"
    },
    var.tags
  )
}

# ==============================================================================
# WORKERS NSG (REQUIRED)
# ==============================================================================
# Applied to: OKE worker node instances
# Purpose: Control traffic to/from worker nodes
# Created: Always
# Key traffic: Kubelet (10250), NodePort services (30000-32767), inter-node

resource "oci_core_network_security_group" "workers_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  display_name   = format("workers-%s", local.state_id)

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "workers"
    },
    var.tags
  )
}

# ==============================================================================
# PODS NSG (REQUIRED)
# ==============================================================================
# Applied to: Pod VNICs in VCN-native networking
# Purpose: Control traffic to/from Kubernetes pods
# Created: Always
# Key traffic: Pod-to-pod, pod-to-services, pod-to-internet

resource "oci_core_network_security_group" "pods_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  display_name   = format("pods-%s", local.state_id)

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "pods"
    },
    var.tags
  )
}

# ==============================================================================
# FILE STORAGE SERVICE (FSS) NSG (OPTIONAL)
# ==============================================================================
# Applied to: FSS mount targets
# Purpose: Control NFS traffic (ports 111, 2048-2050) to shared filesystems
# Created: Only when create_fss_subnet = true

resource "oci_core_network_security_group" "fss_nsg" {
  count = var.create_fss_subnet ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  display_name   = format("fss-%s", local.state_id)

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "fss"
    },
    var.tags
  )
}
