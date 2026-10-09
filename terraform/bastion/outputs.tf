output "bastion_public_ip" {
  value       = aws_instance.bastion.public_ip
  description = "Public IP address of the RHEL 9 Bastion"
}

output "ssh_connection_command" {
  value       = "ssh ec2-user@${aws_instance.bastion.public_ip}"
  description = "Command to SSH into the Bastion host"
}

# Bootstrap takes several minutes and SSH answers long before it finishes, so
# "I logged in and tmux was missing" is as likely to mean "not yet" as
# "failed". cloud-init status --wait blocks until it is genuinely done, and
# the marker file is only written when every expected tool was found.
output "verify_bootstrap_command" {
  value       = "ssh ec2-user@${aws_instance.bastion.public_ip} 'sudo cloud-init status --wait; cat /var/log/bastion-tools.txt; test -f /var/log/bastion-bootstrap-complete && echo BOOTSTRAP OK || echo BOOTSTRAP INCOMPLETE'"
  description = "Waits for first-boot to finish, then reports which tools landed"
}