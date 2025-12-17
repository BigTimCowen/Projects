# ==============================================================================
# CONTROL PLANE SECURITY RULES
# ==============================================================================

# Control Plane to Control Plane communication (for HA control plane)

resource "oci_core_network_security_group_security_rule" "cp_to_cp_tcp_6443" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.cp_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress for Kubernetes control plane inter-communication"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_from_cp_tcp_6443" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.cp_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP ingress for Kubernetes control plane inter-communication"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_to_workers_tcp_10250" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress from OKE control plane to Kubelet on worker nodes"

  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_to_workers_icmp" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "EGRESS"
  protocol                  = "1"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow ICMP egress for path discovery to worker nodes"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "cp_from_workers_tcp_6443" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.workers_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP ingress to kube-apiserver from worker nodes"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_from_pods_tcp_6443" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.pods_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP ingress to kube-apiserver from pods"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

# Operator to Control Plane API access
resource "oci_core_network_security_group_security_rule" "cp_from_operator_tcp_6443" {
  count                     = var.create_operator_subnet ? 1 : 0
  network_security_group_id = local.cp_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.operator_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP ingress to kube-apiserver from operator subnet"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_to_pods_tcp" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.pods_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress from OKE control plane to pods"
}

resource "oci_core_network_security_group_security_rule" "cp_to_workers_tcp" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress from OKE control plane to worker nodes"

  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_to_services_tcp" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.all_oci_services
  destination_type          = "SERVICE_CIDR_BLOCK"
  description               = "Allow TCP egress from OKE control plane to OCI services"
}

resource "oci_core_network_security_group_security_rule" "cp_from_workers_tcp_12250" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.workers_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP ingress to OKE control plane from worker nodes"

  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_from_pods_tcp_12250" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.pods_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP ingress to OKE control plane from pods"

  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_from_internet_tcp_6443" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow TCP ingress to kube-apiserver from 0.0.0.0/0"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_from_workers_icmp" {
  network_security_group_id = local.cp_nsg_id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = local.workers_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow ICMP ingress for path discovery from worker nodes"

  icmp_options {
    type = 3
    code = 4
  }
}