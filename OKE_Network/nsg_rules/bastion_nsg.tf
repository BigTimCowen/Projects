# ==============================================================================
# Bastion SECURITY RULES
# ==============================================================================


resource "oci_core_network_security_group_security_rule" "bastion_from_internet_ssh" {
  count                     = var.create_bastion_subnet ? 1 : 0
  network_security_group_id = local.bastion_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow SSH ingress to bastion from 0.0.0.0/0"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_to_workers_ssh" {
  count                     = var.create_bastion_subnet ? 1 : 0
  network_security_group_id = local.bastion_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow SSH egress from bastion to workers"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}


resource "oci_core_network_security_group_security_rule" "workers_from_bastion_ssh" {
  count                     = var.create_bastion_subnet ? 1 : 0
  network_security_group_id = local.workers_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.bastion_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow SSH ingress to workers from bastion"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# Bastion to Operator SSH access
resource "oci_core_network_security_group_security_rule" "bastion_to_operator_ssh" {
  count                     = var.create_bastion_subnet && var.create_operator_subnet ? 1 : 0
  network_security_group_id = local.bastion_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.operator_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow SSH egress from bastion to operator subnet"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}


#Bastion to access the K8s control plane
resource "oci_core_network_security_group_security_rule" "bastion_to_cp_tcp_6443" {
  count                     = var.create_bastion_subnet ? 1 : 0
  network_security_group_id = local.bastion_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.cp_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress from bastion to cluster endpoint"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

#Bastion to access the service network
resource "oci_core_network_security_group_security_rule" "bastion_to_services_tcp" {
  count                     = var.create_bastion_subnet ? 1 : 0
  network_security_group_id = local.bastion_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.all_oci_services
  destination_type          = "SERVICE_CIDR_BLOCK"
  description               = "Allow TCP egress from bastion to OCI services"
}

#Bastion to Access K8s control plane
resource "oci_core_network_security_group_security_rule" "cp_from_bastion_tcp_6443" {
  count                     = var.create_bastion_subnet ? 1 : 0
  network_security_group_id = local.cp_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.bastion_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP ingress to kube-apiserver from bastion host"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}
