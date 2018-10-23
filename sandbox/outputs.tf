output "1 - Sandbox SSH" { value = "ssh opc@${data.oci_core_vnic.sandbox_vnic.public_ip_address}" }
output "2 - Cloudera Guided Demo" { value = "http://${data.oci_core_vnic.sandbox_vnic.public_ip_address}/" }
output "3 - HUE Login" { value = "http://${data.oci_core_vnic.sandbox_vnic.public_ip_address}:8888/" }
output "4 - Cloudera Manager Login" { value = "http://${data.oci_core_vnic.sandbox_vnic.public_ip_address}:7180/cmf/" }
