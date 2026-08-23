data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Networking
#
# The default VPC is deliberate. A DCS server for friends needs one public
# instance and nothing else; a bespoke VPC would add NAT gateways ($32/month)
# and moving parts for no benefit whatsoever.
# ---------------------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

# Not every instance type exists in every AZ -- this is a real failure mode for
# the newer families. Restrict subnet choice to AZs that actually offer ours.
data "aws_ec2_instance_type_offerings" "by_az" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_subnets" "usable" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.by_az.locations
  }
}

data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }
}

# ---------------------------------------------------------------------------
# Security group
#
# Game traffic only. RDP (3389) and the DCS WebGUI (8088) are deliberately
# absent -- both are reached by tunnelling through SSM Session Manager, which
# requires no inbound rule at all. An internet-facing RDP port on a Windows box
# is found by scanners within hours.
# ---------------------------------------------------------------------------

resource "aws_security_group" "dcs" {
  name_prefix = "dcs-server-"
  description = "DCS dedicated server: game traffic only, admin via SSM"
  vpc_id      = data.aws_vpc.default.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "dcs_tcp" {
  security_group_id = aws_security_group.dcs.id
  description       = "DCS game traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = var.dcs_port
  to_port           = var.dcs_port
}

resource "aws_vpc_security_group_ingress_rule" "dcs_udp" {
  security_group_id = aws_security_group.dcs.id
  description       = "DCS game traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = var.dcs_port
  to_port           = var.dcs_port
}

resource "aws_vpc_security_group_ingress_rule" "srs_tcp" {
  count = var.enable_srs ? 1 : 0

  security_group_id = aws_security_group.dcs.id
  description       = "SimpleRadio Standalone"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = var.srs_port
  to_port           = var.srs_port
}

resource "aws_vpc_security_group_ingress_rule" "srs_udp" {
  count = var.enable_srs ? 1 : 0

  security_group_id = aws_security_group.dcs.id
  description       = "SimpleRadio Standalone"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = var.srs_port
  to_port           = var.srs_port
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.dcs.id
  description       = "Outbound for Windows Update, SSM and the DCS updater"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Instance IAM role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name_prefix        = "dcs-instance-"
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json
}

# Gives Session Manager, and with it RDP/WebGUI tunnelling with zero open ports.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance_self_manage" {
  # The watchdog stops the instance from inside the guest. Scoping by tag rather
  # than by instance ID avoids a Terraform dependency cycle (the policy would
  # otherwise need the instance ID, and the instance needs the policy).
  statement {
    sid       = "StopSelf"
    actions   = ["ec2:StopInstances"]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Project"
      values   = ["dcs-server"]
    }
  }

  # Player count, published for /dcs status. Standard-tier parameters are free.
  statement {
    sid       = "PublishPlayerCount"
    actions   = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/dcs/*"]
  }

  # The Discord webhook is stored as a SecureString, so reading it needs KMS
  # decrypt against the AWS-managed SSM key. Without this the perf report fails
  # with AccessDenied at the very last step, after doing all the work.
  statement {
    sid       = "DecryptSsmSecureStrings"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }

  # The instance publishes live telemetry for the web board. Scoped to the
  # data/ prefix so it can never overwrite the app itself.
  statement {
    sid       = "PublishBoardData"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${var.board_bucket}/data/*"]
  }

  # Read-only access to the transfer bucket, used to hand large files (aircraft
  # mods) to the server without them passing through Discord's size limits or a
  # Lambda. Objects there expire after 7 days so a forgotten upload cannot
  # quietly accrue storage cost.
  # Campaign saves are the one genuinely irreplaceable thing on this disk --
  # hours of a group's progress that cannot be re-downloaded like the DCS
  # install or the mod. Write access is scoped to this prefix only.
  statement {
    sid       = "WriteCampaignBackups"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${var.transfer_bucket}/campaign-backups/*"]
  }

  statement {
    sid     = "ReadTransferBucket"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.transfer_bucket}",
      "arn:aws:s3:::${var.transfer_bucket}/*",
    ]
  }
}

resource "aws_iam_role_policy" "instance_self_manage" {
  name_prefix = "dcs-self-manage-"
  role        = aws_iam_role.instance.id
  policy      = data.aws_iam_policy_document.instance_self_manage.json
}

resource "aws_iam_instance_profile" "instance" {
  name_prefix = "dcs-instance-"
  role        = aws_iam_role.instance.name
}

# ---------------------------------------------------------------------------
# The server
# ---------------------------------------------------------------------------

resource "aws_instance" "dcs" {
  ami           = data.aws_ami.windows.id
  instance_type = var.instance_type
  subnet_id     = data.aws_subnets.usable.ids[0]
  key_name      = var.key_pair_name

  vpc_security_group_ids = [aws_security_group.dcs.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # The watchdog calls `shutdown /s` from inside Windows. Without this, that
  # would TERMINATE the instance and destroy the DCS install.
  instance_initiated_shutdown_behavior = "stop"

  # The whole point: pay the Windows licence on 4 vCPUs instead of 8.
  cpu_options {
    core_count       = var.core_count
    threads_per_core = var.threads_per_core
  }

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    iops        = 3000 # included free
    throughput  = 125  # included free
    encrypted   = true

    # A day of downloading and configuring DCS lives on this volume.
    delete_on_termination = false

    tags = {
      Name    = "${var.server_name}-root"
      Project = "dcs-server" # matched by the DLM snapshot policy
    }
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  user_data = templatefile("${path.module}/user_data.ps1.tftpl", {
    windows_timezone = var.windows_timezone
    dcs_port         = var.dcs_port
    srs_port         = var.srs_port
    enable_srs       = var.enable_srs
  })

  tags = {
    Name = var.server_name
  }

  lifecycle {
    # Amazon publishes a new Windows AMI monthly. Without this, a routine
    # `terraform apply` would replace the instance and take the DCS install
    # with it. Rebuild deliberately from your own AMI instead (see README).
    ignore_changes = [ami, user_data]
  }
}

# ---------------------------------------------------------------------------
# Stable address
#
# $3.65/month. The alternative -- auto-assigned IP plus a boot-time DNS update
# -- saves $3.47 and adds a moving part that fails at the worst moment. Paying
# is the right call for a friends' server.
# ---------------------------------------------------------------------------

resource "aws_eip" "dcs" {
  domain = "vpc"

  tags = {
    Name = "${var.server_name}-eip"
  }
}

resource "aws_eip_association" "dcs" {
  instance_id   = aws_instance.dcs.id
  allocation_id = aws_eip.dcs.id
}
