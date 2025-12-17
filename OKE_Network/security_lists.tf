# Copyright (c) 2025 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

resource "oci_core_security_list" "pub_lb" {
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

resource "oci_core_security_list" "int_lb" {
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
