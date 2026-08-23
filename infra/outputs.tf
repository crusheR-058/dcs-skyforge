locals {
  # Verified against the AWS Pricing API on 2026-08-19. Both Indian regions
  # price gp3 identically. Used only for the informational cost outputs below.
  gp3_usd_per_gb_month = {
    "ap-south-1" = 0.0912
    "ap-south-2" = 0.0912
    "us-east-1"  = 0.0800
  }

  gp3_rate      = lookup(local.gp3_usd_per_gb_month, var.region, 0.0912)
  active_vcpus  = var.core_count * var.threads_per_core
  license_rate  = local.active_vcpus * 0.046
  storage_month = var.root_volume_gb * local.gp3_rate
  eip_month     = 0.005 * 730
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.dcs.id
}

output "server_address" {
  description = "Give this to your friends. Paste it into DCS: Multiplayer > Connect by IP."
  value       = "${aws_eip.dcs.public_ip}:${var.dcs_port}"
}

output "public_ip" {
  description = "Elastic IP. Stable across stop/start, which is the point of paying for it."
  value       = aws_eip.dcs.public_ip
}

output "discord_interactions_url" {
  description = "Paste into Discord Developer Portal > General Information > Interactions Endpoint URL."
  value       = local.deploy_bot ? aws_apigatewayv2_stage.bot[0].invoke_url : "bot not deployed (discord_public_key is empty)"
}

output "get_administrator_password" {
  description = "Decrypt the Windows Administrator password using your key pair."
  value       = "aws ec2 get-password-data --instance-id ${aws_instance.dcs.id} --priv-launch-key <path-to>.pem --region ${var.region}"
}

output "rdp_tunnel" {
  description = "Open an RDP tunnel with no inbound port open. Then connect mstsc to localhost:13389."
  value       = "aws ssm start-session --target ${aws_instance.dcs.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=3389,localPortNumber=13389 --region ${var.region}"
}

output "webgui_tunnel" {
  description = "Tunnel the DCS WebGUI, then browse to http://localhost:8088."
  value       = "aws ssm start-session --target ${aws_instance.dcs.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=8088,localPortNumber=8088 --region ${var.region}"
}

output "start_server" {
  description = "Start the server from the CLI (the Discord bot does the same thing)."
  value       = "aws ec2 start-instances --instance-ids ${aws_instance.dcs.id} --region ${var.region}"
}

output "stop_server" {
  description = "Stop the server from the CLI."
  value       = "aws ec2 stop-instances --instance-ids ${aws_instance.dcs.id} --region ${var.region}"
}

output "cost_summary" {
  description = "Informational estimate, pre-GST. AWS India adds 18% on top."
  value = {
    instance_type = var.instance_type
    active_vcpus  = local.active_vcpus

    windows_license_usd_per_hour = format("%.4f", local.license_rate)

    hyperthreading = (
      var.threads_per_core == 1
      ? format("DISABLED - licensing %d vCPUs", local.active_vcpus)
      : format("ENABLED - licensing %d vCPUs, costing %.4f USD/hr more than necessary", local.active_vcpus, local.active_vcpus * 0.046 / 2)
    )

    # This is the number that surprises people: it accrues whether or not you
    # ever boot the instance. Excludes snapshots (~$2.28/mo), which vary with
    # how much actually changes on disk between weekly runs.
    always_on_floor_usd_per_month = format("%.2f (storage + IP; add ~2.28 for snapshots)", local.storage_month + local.eip_month)

    breakdown = {
      storage    = format("%d GB gp3 at %.4f USD/GB-mo = %.2f USD/mo", var.root_volume_gb, local.gp3_rate, local.storage_month)
      elastic_ip = format("730 hrs at 0.005 USD = %.2f USD/mo", local.eip_month)
    }

    note = "Add the instance baseline rate x hours played. See README.md for the full model."
  }
}
