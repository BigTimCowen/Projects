# ==============================================================================
# Public Load Balancer SECURITY RULES
# ==============================================================================


resource "oci_core_network_security_group_security_rule" "pub_lb_from_internet_tcp_80" {
  count                     = var.create_public_subnets ? 1 : 0
  network_security_group_id = local.pub_lb_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow TCP ingress from anywhere to HTTP port"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "pub_lb_from_internet_tcp_443" {
  count                     = var.create_public_subnets ? 1 : 0
  network_security_group_id = local.pub_lb_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow TCP ingress from anywhere to HTTPS port"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "pub_lb_to_workers_tcp_health" {
  count                     = var.create_public_subnets ? 1 : 0
  network_security_group_id = local.pub_lb_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress from public load balancers to worker nodes for health checks"

  tcp_options {
    destination_port_range {
      min = 10256
      max = 10256
    }
  }
}

resource "oci_core_network_security_group_security_rule" "pub_lb_to_workers_tcp_nodeport" {
  count                     = var.create_public_subnets ? 1 : 0
  network_security_group_id = local.pub_lb_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress from public load balancers to workers nodes for NodePort traffic"

  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "pub_lb_to_workers_icmp" {
  count                     = var.create_public_subnets ? 1 : 0
  network_security_group_id = local.pub_lb_nsg_id
  direction                 = "EGRESS"
  protocol                  = "1"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow ICMP egress from public load balancers to worker nodes for path discovery"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "pub_lb_to_workers_udp_nodeport" {
  count                     = var.create_public_subnets ? 1 : 0
  network_security_group_id = local.pub_lb_nsg_id
  direction                 = "EGRESS"
  protocol                  = "17"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow UDP egress from public load balancers to workers nodes for NodePort traffic"

  udp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}
