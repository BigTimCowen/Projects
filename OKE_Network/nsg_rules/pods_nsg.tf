# ==============================================================================
# PODS SECURITY RULES
# ==============================================================================

resource "oci_core_network_security_group_security_rule" "pods_to_pods_all" {
  network_security_group_id = local.pods_nsg_id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = local.pods_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow ALL egress from pods to other pods"
}

resource "oci_core_network_security_group_security_rule" "pods_from_pods_all" {
  network_security_group_id = local.pods_nsg_id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = local.pods_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow ALL ingress to pods from other pods"
}

resource "oci_core_network_security_group_security_rule" "pods_to_workers_all" {
  network_security_group_id = local.pods_nsg_id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = local.workers_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow ALL egress from pods for cross-node pod communication when using NodePorts or hostNetwork: true"
}

resource "oci_core_network_security_group_security_rule" "pods_from_workers_all" {
  network_security_group_id = local.pods_nsg_id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = local.workers_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow ALL ingress to pods for cross-node pod communication when using NodePorts or hostNetwork: true"
}

resource "oci_core_network_security_group_security_rule" "pods_from_cp_all" {
  network_security_group_id = local.pods_nsg_id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = local.cp_nsg_id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow ALL ingress to pods from Kubernetes control plane for webhooks served by pods"
}

resource "oci_core_network_security_group_security_rule" "pods_to_internet_all" {
  network_security_group_id = local.pods_nsg_id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow ALL egress from pods to internet"
}

resource "oci_core_network_security_group_security_rule" "pods_to_services_tcp" {
  network_security_group_id = local.pods_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.all_oci_services
  destination_type          = "SERVICE_CIDR_BLOCK"
  description               = "Allow TCP egress from pods to OCI Services"
}

resource "oci_core_network_security_group_security_rule" "pods_to_internet_icmp" {
  network_security_group_id = local.pods_nsg_id
  direction                 = "EGRESS"
  protocol                  = "1"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow ICMP egress from pods for path discovery"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "pods_from_internet_icmp" {
  network_security_group_id = local.pods_nsg_id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow ICMP ingress to pods for path discovery"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "pods_to_cp_tcp_6443" {
  network_security_group_id = local.pods_nsg_id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.cp_nsg_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow TCP egress from pods to Kubernetes API server"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}
