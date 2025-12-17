
# ==============================================================================
# Internal Load balancer SECURITY RULES
# ==============================================================================



resource "oci_core_network_security_group_security_rule" "int_lb_from_vcn_all" {
  network_security_group_id = local.int_lb_nsg_id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = local.vcn_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Allow TCP ingress to internal load balancers from internal VCN/DRG"
}

resource "oci_core_network_security_group_security_rule" "int_lb_to_workers_tcp_health" {
  network_security_group_id = local.int_lb_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress from internal load balancers to worker nodes for health checks"

  tcp_options {
    destination_port_range {
      min = 10256
      max = 10256
    }
  }
}

resource "oci_core_network_security_group_security_rule" "int_lb_to_workers_tcp_nodeport" {
  network_security_group_id = local.int_lb_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress from internal load balancers to workers for Node Ports"

  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "int_lb_to_workers_udp_nodeport" {
  network_security_group_id = local.int_lb_nsg_id
  direction                 = "EGRESS"
  protocol                  = "17"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow UDP egress from internal load balancers to workers for Node Ports"

  udp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "int_lb_to_workers_icmp" {
  network_security_group_id = local.int_lb_nsg_id
  direction                 = "EGRESS"
  protocol                  = "1"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow ICMP egress from internal load balancers to worker nodes for path discovery"

  icmp_options {
    type = 3
    code = 4
  }
}
