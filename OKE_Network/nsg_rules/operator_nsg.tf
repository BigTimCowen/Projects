# ==============================================================================
# Operator SECURITY RULES
# ==============================================================================

resource "oci_core_network_security_group_security_rule" "operator_to_internet_all" {
  network_security_group_id = local.operator_nsg_id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow ALL egress from operator to internet"
}

resource "oci_core_network_security_group_security_rule" "bastion_to_operator_icmp" {
  network_security_group_id = local.operator_nsg_id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = local.bastion_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow ICMP ingress for path discovery from bastion nodes"

  icmp_options {
    type = 3
    code = 4
  }
}


resource "oci_core_network_security_group_security_rule" "operator_from_bastion_ssh" {
  count                     = var.create_bastion_subnet && var.create_operator_subnet ? 1 : 0
  network_security_group_id = local.operator_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.bastion_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow SSH ingress to operator from bastion"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# Operator to Control Plane API access
resource "oci_core_network_security_group_security_rule" "operator_to_cp_tcp_6443" {
  count                     = var.create_operator_subnet ? 1 : 0
  network_security_group_id = local.operator_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.cp_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress from operator to kube-apiserver"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

#Operator to access the service network
resource "oci_core_network_security_group_security_rule" "operator_to_services_tcp" {
  count                     = var.create_operator_subnet ? 1 : 0
  network_security_group_id = local.operator_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.all_oci_services
  destination_type          = "SERVICE_CIDR_BLOCK"
  description               = "Allow TCP egress from operator to OCI services"
}
