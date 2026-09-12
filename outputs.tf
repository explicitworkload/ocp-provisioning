output "bastion_public_ip" {
  value       = aws_instance.bastion.public_ip
  description = "Public IP address of the RHEL 9 Bastion"
}

output "ssh_connection_command" {
  value       = "ssh ec2-user@${aws_instance.bastion.public_ip}"
  description = "Command to SSH into the Bastion host"
}