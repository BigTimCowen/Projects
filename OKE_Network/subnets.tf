# Copyright (c) 2025 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

# ==============================================================================
# SUBNET CONFIGURATION FOR OKE
# ==============================================================================
# This file defines all subnets for the OKE cluster:
# - Control Plane: For Kubernetes API server (private by default)
# - Workers: For Kubernetes worker nodes (private)
# - Pods: For pod networking using VCN-native networking (private)
# - Internal LB: For private load balancers (private)
# - Public LB: For internet-facing load balancers (public, optional)
# - Bastion: For SSH access to cluster (public, optional)
# - Operator: For cluster administration/CI-CD (public, optional)
# - FSS: For OCI File Storage Service mount targets (private, optional)
# - Lustre: For Lustre parallel filesystem (private, optional)

locals {
  # Use the first VCN CIDR for subnet calculations
  vcn_cidr = local.vcn_cidrs[0]
  
  # Subnet CIDR blocks - use custom values if provided, otherwise auto-calculate
  # This allows users to either specify exact CIDRs or rely on automatic allocation
  # If CIDR matches default, recalculate based on actual VCN CIDR; otherwise use provided value
  bastion_cidr  = var.bastion_subnet_cidr == "10.140.0.0/29" ? cidrsubnet(local.vcn_cidr, 13, 1) : var.bastion_subnet_cidr
  operator_cidr = var.operator_subnet_cidr == "10.140.0.96/29" ? cidrsubnet(local.vcn_cidr, 13, 2) : var.operator_subnet_cidr
  int_lb_cidr   = var.int_lb_subnet_cidr == "10.140.0.64/27" ? cidrsubnet(local.vcn_cidr, 11, 1) : var.int_lb_subnet_cidr
  pub_lb_cidr   = var.pub_lb_subnet_cidr == "10.140.32.0/27" ? cidrsubnet(local.vcn_cidr, 11, 2) : var.pub_lb_subnet_cidr
  cp_cidr       = var.cp_subnet_cidr == "10.140.0.8/29" ? cidrsubnet(local.vcn_cidr, 13, 0) : var.cp_subnet_cidr
  workers_cidr  = var.workers_subnet_cidr == "10.140.48.0/20" ? cidrsubnet(local.vcn_cidr, 4, 2) : var.workers_subnet_cidr
  pods_cidr     = var.pods_subnet_cidr == "10.140.16.0/20" ? cidrsubnet(local.vcn_cidr, 2, 2) : var.pods_subnet_cidr
  fss_cidr      = var.fss_subnet_cidr == "10.140.0.32/27" ? cidrsubnet(local.vcn_cidr, 11, 3) : var.fss_subnet_cidr
  lustre_cidr   = var.lustre_subnet_cidr == "10.140.1.0/24" ? cidrsubnet(local.vcn_cidr, 7, 1) : var.lustre_subnet_cidr
  
  # Subnet display names - use custom values if provided, otherwise use defaults with state_id
  # If user provides a custom name, use it as-is; if using default, append state_id for uniqueness
  bastion_name  = var.bastion_subnet_name == "bastion" ? format("bastion-%s", local.state_id) : var.bastion_subnet_name
  operator_name = var.operator_subnet_name == "operator" ? format("operator-%s", local.state_id) : var.operator_subnet_name
  int_lb_name   = var.int_lb_subnet_name == "int_lb" ? format("int_lb-%s", local.state_id) : var.int_lb_subnet_name
  pub_lb_name   = var.pub_lb_subnet_name == "pub_lb" ? format("pub_lb-%s", local.state_id) : var.pub_lb_subnet_name
  cp_name       = var.cp_subnet_name == "cp" ? format("cp-%s", local.state_id) : var.cp_subnet_name
  workers_name  = var.workers_subnet_name == "workers" ? format("workers-%s", local.state_id) : var.workers_subnet_name
  pods_name     = var.pods_subnet_name == "pods" ? format("pods-%s", local.state_id) : var.pods_subnet_name
  fss_name      = var.fss_subnet_name == "fss" ? format("fss-%s", local.state_id) : var.fss_subnet_name
  lustre_name   = var.lustre_subnet_name == "lustre" ? format("lustre-%s", local.state_id) : var.lustre_subnet_name
}

# ==============================================================================
# BASTION SUBNET (OPTIONAL, PUBLIC)
# ==============================================================================
# Purpose: SSH jump host access to private resources
# Size: /29 (8 IPs, calculated as cidrsubnet(/16, 13, 1))
# Route: Internet Gateway for public access (creates dependency on IGW)
# Created: Only when create_bastion_subnet = true
# CIDR: Customizable via bastion_subnet_cidr variable
# Note: Bastion requires Internet Gateway to be created

resource "oci_core_subnet" "bastion" {
  count = var.create_bastion_subnet ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  cidr_block     = local.bastion_cidr  # Uses custom CIDR if provided

  display_name               = local.bastion_name
  dns_label                  = var.assign_dns ? "ba" : null
  prohibit_public_ip_on_vnic = false  # Allow public IPs
  prohibit_internet_ingress  = false  # Allow inbound internet traffic

  route_table_id = module.vcn.ig_route_id  # Uses Internet Gateway route table
  security_list_ids = [module.vcn.default_security_list_id]

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "bastion"
    },
    var.tags
  )

  # Ensure Internet Gateway is created when bastion is enabled
  depends_on = [module.vcn]
}

# ==============================================================================
# OPERATOR SUBNET (OPTIONAL, PRIVATE)
# ==============================================================================
# Purpose: Administrative access, CI/CD runners, cluster operators
# Size: /29 (8 IPs, calculated as cidrsubnet(/16, 13, 2))
# Route: NAT Gateway for outbound internet access
# Created: Only when create_operator_subnet = true
# CIDR: Customizable via operator_subnet_cidr variable
# Note: Operator is private and uses NAT gateway

resource "oci_core_subnet" "operator" {
  count = var.create_operator_subnet ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  cidr_block     = local.operator_cidr  # Uses custom CIDR if provided

  display_name               = local.operator_name
  dns_label                  = var.assign_dns ? "op" : null
  prohibit_public_ip_on_vnic = true  # No public IPs (private subnet)
  prohibit_internet_ingress  = true  # No inbound internet traffic

  route_table_id = module.vcn.nat_route_id  # Uses NAT Gateway route table
  security_list_ids = [module.vcn.default_security_list_id]

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "operator"
    },
    var.tags
  )

  # Ensure NAT Gateway is created when operator is enabled
  depends_on = [module.vcn]
}

# ==============================================================================
# INTERNAL LOAD BALANCER SUBNET (REQUIRED, PRIVATE)
# ==============================================================================
# Purpose: Private load balancers for internal services
# Size: /21 (2048 IPs, calculated as cidrsubnet(/16, 11, 1))
# Route: NAT Gateway for outbound internet access
# Created: Always
# CIDR: Customizable via int_lb_subnet_cidr variable

resource "oci_core_subnet" "int_lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  cidr_block     = local.int_lb_cidr  # Uses custom CIDR if provided

  display_name               = local.int_lb_name
  dns_label                  = var.assign_dns ? "in" : null
  prohibit_public_ip_on_vnic = true  # No public IPs allowed
  prohibit_internet_ingress  = true  # No inbound internet traffic

  route_table_id = module.vcn.nat_route_id  # Use NAT Gateway route table
  security_list_ids = [oci_core_security_list.int_lb.id]

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "int_lb"
    },
    var.tags
  )
}

# ==============================================================================
# PUBLIC LOAD BALANCER SUBNET (OPTIONAL, PUBLIC)
# ==============================================================================
# Purpose: Internet-facing load balancers for public services
# Size: /21 (2048 IPs, calculated as cidrsubnet(/16, 11, 2))
# Route: Internet Gateway for public access
# Created: Only when create_public_subnets = true
# CIDR: Customizable via pub_lb_subnet_cidr variable

resource "oci_core_subnet" "pub_lb" {
  count = var.create_public_subnets ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  cidr_block     = local.pub_lb_cidr  # Uses custom CIDR if provided

  display_name               = local.pub_lb_name
  dns_label                  = var.assign_dns ? "pu" : null
  prohibit_public_ip_on_vnic = false  # Allow public IPs
  prohibit_internet_ingress  = false  # Allow inbound internet traffic

  route_table_id = module.vcn.ig_route_id  # Use Internet Gateway route table
  security_list_ids = [oci_core_security_list.pub_lb[0].id]

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "pub_lb"
    },
    var.tags
  )
}

# ==============================================================================
# CONTROL PLANE SUBNET (REQUIRED, PUBLIC BY DEFAULT)
# ==============================================================================
# Purpose: Kubernetes API server and control plane components
# Size: /29 (8 IPs, calculated as cidrsubnet(/16, 13, 0))
# Route: Internet Gateway (public, default) or NAT Gateway (private, optional)
# Created: Always
# CIDR: Customizable via cp_subnet_cidr variable
# Note: Default is PUBLIC for easier access; can be made private via control_plane_is_public flag

resource "oci_core_subnet" "cp" {
  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  cidr_block     = local.cp_cidr  # Uses custom CIDR if provided

  display_name               = local.cp_name
  dns_label                  = var.assign_dns ? "cp" : null
  prohibit_public_ip_on_vnic = !var.control_plane_is_public  # Public IPs only if explicitly enabled
  prohibit_internet_ingress  = !var.control_plane_is_public  # Inbound internet only if explicitly enabled

  # Use Internet Gateway if control plane is public, otherwise NAT Gateway
  route_table_id = var.control_plane_is_public ? module.vcn.ig_route_id : module.vcn.nat_route_id
  security_list_ids = [module.vcn.default_security_list_id]

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "control_plane"
    },
    var.tags
  )
}

# ==============================================================================
# WORKERS SUBNET (REQUIRED, PRIVATE)
# ==============================================================================
# Purpose: Kubernetes worker nodes that run containerized workloads
# Size: /20 (4096 IPs, calculated as cidrsubnet(/16, 4, 2))
# Route: NAT Gateway for outbound internet access
# Created: Always
# CIDR: Customizable via workers_subnet_cidr variable

resource "oci_core_subnet" "workers" {
  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  cidr_block     = local.workers_cidr  # Uses custom CIDR if provided

  display_name               = local.workers_name
  dns_label                  = var.assign_dns ? "wo" : null
  prohibit_public_ip_on_vnic = true  # No public IPs on worker nodes
  prohibit_internet_ingress  = true  # No inbound internet traffic

  route_table_id = module.vcn.nat_route_id  # Use NAT Gateway route table
  security_list_ids = [module.vcn.default_security_list_id]

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "workers"
    },
    var.tags
  )
}

# ==============================================================================
# PODS SUBNET (REQUIRED, PRIVATE)
# ==============================================================================
# Purpose: VCN-native pod networking (each pod gets a VCN IP)
# Size: /18 (16384 IPs, calculated as cidrsubnet(/16, 2, 2))
# Route: NAT Gateway for outbound internet access
# Created: Always
# CIDR: Customizable via pods_subnet_cidr variable
# Note: Large CIDR required for high pod density in GPU workloads

resource "oci_core_subnet" "pods" {
  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  cidr_block     = local.pods_cidr  # Uses custom CIDR if provided

  display_name               = local.pods_name
  dns_label                  = var.assign_dns ? "po" : null
  prohibit_public_ip_on_vnic = true  # No public IPs on pods
  prohibit_internet_ingress  = true  # No inbound internet traffic

  route_table_id = module.vcn.nat_route_id  # Use NAT Gateway route table
  security_list_ids = [module.vcn.default_security_list_id]

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "pods"
    },
    var.tags
  )
}

# ==============================================================================
# FILE STORAGE SERVICE (FSS) SUBNET (OPTIONAL, PRIVATE)
# ==============================================================================
# Purpose: OCI File Storage Service mount targets for shared filesystem
# Size: /21 (2048 IPs, calculated as cidrsubnet(/16, 11, 3))
# Route: NAT Gateway for outbound access
# Created: Only when create_fss_subnet = true
# CIDR: Customizable via fss_subnet_cidr variable

resource "oci_core_subnet" "fss" {
  count = var.create_fss_subnet ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  cidr_block     = local.fss_cidr  # Uses custom CIDR if provided

  display_name               = local.fss_name
  dns_label                  = var.assign_dns ? "fss" : null
  prohibit_public_ip_on_vnic = true  # No public IPs
  prohibit_internet_ingress  = true  # No inbound internet traffic

  route_table_id = module.vcn.nat_route_id  # Use NAT Gateway route table
  security_list_ids = [module.vcn.default_security_list_id]

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "fss"
    },
    var.tags
  )
}

# ==============================================================================
# LUSTRE SUBNET (OPTIONAL, PRIVATE)
# ==============================================================================
# Purpose: Lustre parallel filesystem for high-performance computing workloads
# Size: /23 (512 IPs, calculated as cidrsubnet(/16, 7, 1))
# Route: NAT Gateway for outbound access
# Created: Only when create_lustre_subnet = true
# CIDR: Customizable via lustre_subnet_cidr variable

resource "oci_core_subnet" "lustre" {
  count = var.create_lustre_subnet ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = module.vcn.vcn_id
  cidr_block     = local.lustre_cidr  # Uses custom CIDR if provided

  display_name               = local.lustre_name
  dns_label                  = var.assign_dns ? "lustre" : null
  prohibit_public_ip_on_vnic = true  # No public IPs
  prohibit_internet_ingress  = true  # No inbound internet traffic

  route_table_id = module.vcn.nat_route_id  # Use NAT Gateway route table
  security_list_ids = [module.vcn.default_security_list_id]

  freeform_tags = merge(
    {
      "state_id" = local.state_id,
      "role"     = "lustre"
    },
    var.tags
  )
}
