# ==============================================================================
# Worker SECURITY RULES
# ==============================================================================

resource "oci_core_network_security_group_security_rule" "workers_to_workers_all" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow ALL egress from workers to other workers"
}

resource "oci_core_network_security_group_security_rule" "workers_from_workers_all" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = local.workers_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow ALL ingress to workers from other workers"
}

resource "oci_core_network_security_group_security_rule" "workers_to_pods_all" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = local.pods_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow ALL egress from workers to pods"
}

resource "oci_core_network_security_group_security_rule" "workers_from_pods_all" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = local.pods_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow ALL ingress to workers from pods"
}

resource "oci_core_network_security_group_security_rule" "workers_to_cp_tcp_6443" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.cp_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress from workers to Kubernetes API server"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_to_cp_tcp_12250" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.cp_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress from workers to OKE control plane"

  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_to_cp_tcp_10250" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.cp_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress to OKE control plane from workers for health check"

  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_from_cp_all" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = local.cp_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow ALL ingress to workers from Kubernetes control plane for webhooks served by workers"
}

resource "oci_core_network_security_group_security_rule" "workers_to_internet_all" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow ALL egress from workers to internet"
}

resource "oci_core_network_security_group_security_rule" "workers_to_services_tcp" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.all_oci_services
  destination_type          = "SERVICE_CIDR_BLOCK"
  description               = "Allow TCP egress from workers to OCI Services"
}

resource "oci_core_network_security_group_security_rule" "workers_to_internet_icmp" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "EGRESS"
  protocol                  = "1"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow ICMP egress from workers for path discovery"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "workers_from_internet_icmp" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow ICMP ingress to workers for path discovery"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "workers_from_pub_lb_tcp_health" {
  count                     = var.create_public_subnets ? 1 : 0
  network_security_group_id = local.workers_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.pub_lb_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP ingress from public load balancers to worker nodes for health checks"

  tcp_options {
    destination_port_range {
      min = 10256
      max = 10256
    }
  }
}


resource "oci_core_network_security_group_security_rule" "workers_from_int_lb_tcp_health" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.int_lb_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP ingress from internal load balancers to worker nodes for health checks"

  tcp_options {
    destination_port_range {
      min = 10256
      max = 10256
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_from_int_lb_tcp_nodeport" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.int_lb_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP ingress to workers from internal load balancers"

  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_from_int_lb_udp_nodeport" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = local.int_lb_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow UDP ingress to workers from internal load balancers"

  udp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_from_pub_lb_udp_nodeport" {
  count                     = var.create_public_subnets ? 1 : 0
  network_security_group_id = local.workers_nsg_id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = local.pub_lb_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow UDP ingress to workers from public load balancers"

  udp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_from_pub_lb_tcp_nodeport" {
  count                     = var.create_public_subnets ? 1 : 0
  network_security_group_id = local.workers_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.pub_lb_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP ingress to workers from public load balancers"

  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}