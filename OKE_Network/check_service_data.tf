# Test to see what fields are available
output "service_debug" {
  value = {
    id         = try(data.oci_core_services.all_services.services[0].id, "no-id")
    name       = try(data.oci_core_services.all_services.services[0].name, "no-name")
    cidr_block = try(data.oci_core_services.all_services.services[0].cidr_block, "no-cidr")
  }
}
