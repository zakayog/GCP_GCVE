output "panorama_private_ips" {
  description = "Private IP address of the Panorama instance."
  value       = { for k, v in module.panorama : k => v.panorama_private_ip }
}

output "panorama_public_ips" {
  description = "Public IP address of the Panorama instance."
  value       = { for k, v in module.panorama : k => v.panorama_public_ip }
}