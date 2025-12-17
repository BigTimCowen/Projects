# Copyright (c) 2025 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

locals {
  group_name          = format("oke-vcn-%v", local.state_id)
  compartment_matches = format("instance.compartment.id = '%v'", var.compartment_ocid)
  compartment_rule    = format("ANY {%v}", join(", ", [local.compartment_matches]))

  # Policies required for OKE cluster deployment with this VCN
  # These allow self-managed nodes to function properly
  rule_templates = [
    "Allow dynamic-group %v to use virtual-network-family in compartment id %v",
    "Allow dynamic-group %v to use vnics in compartment id %v",
    "Allow dynamic-group %v to use network-security-groups in compartment id %v",
    "Allow dynamic-group %v to use subnets in compartment id %v",
    "Allow dynamic-group %v to inspect compartments in compartment id %v",
  ]

  policy_statements = [for s in local.rule_templates : format(s, local.group_name, var.compartment_ocid)]
}

resource "oci_identity_dynamic_group" "vcn_quickstart" {
  provider       = oci.home
  count          = var.create_policies ? 1 : 0
  compartment_id = var.tenancy_ocid # dynamic groups exist in root compartment (tenancy)
  name           = local.group_name
  description    = format("Dynamic group for OKE VCN Terraform state %v", local.state_id)
  matching_rule  = local.compartment_rule
  lifecycle {
    ignore_changes = [defined_tags]
  }
}

resource "oci_identity_policy" "vcn_quickstart" {
  provider       = oci.home
  count          = var.create_policies ? 1 : 0
  compartment_id = var.compartment_ocid
  name           = local.group_name
  description    = format("Policies for OKE VCN Terraform state %v", local.state_id)
  statements     = local.policy_statements
  lifecycle {
    ignore_changes = [defined_tags]
  }
}
