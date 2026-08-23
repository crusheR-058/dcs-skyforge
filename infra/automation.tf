# ---------------------------------------------------------------------------
# Cost safety nets
#
# Three independent mechanisms stop this instance, on purpose:
#
#   1. In-guest watchdog   (server\watchdog.ps1) -- 0 players for 20 min
#   2. Nightly force-stop  (this file)           -- fires regardless
#   3. Budget alarm        (this file)           -- tells a human
#
# They are independent because the realistic failure mode of this project is
# not technical, it is a forgotten running instance: ~$547/month against a
# ~$48/month target. Any one of these can fail without the others noticing.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name_prefix        = "dcs-scheduler-"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler_stop" {
  statement {
    actions   = ["ec2:StopInstances"]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.dcs.id}"]
  }
}

resource "aws_iam_role_policy" "scheduler_stop" {
  name_prefix = "dcs-scheduler-stop-"
  role        = aws_iam_role.scheduler.id
  policy      = data.aws_iam_policy_document.scheduler_stop.json
}

resource "aws_scheduler_schedule" "nightly_stop" {
  name        = "${var.server_name}-nightly-stop"
  description = "Backstop: force-stop the DCS server nightly regardless of watchdog state"
  group_name  = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.nightly_stop_cron
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = [aws_instance.dcs.id]
    })

    # Stopping an already-stopped instance is a harmless no-op, so there is
    # nothing worth retrying and nothing worth alerting on.
    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.server_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Deliberately account-wide rather than tag-filtered: an untagged resource you
  # forgot about is exactly the thing a budget alarm exists to catch.

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.admin_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.admin_email]
  }
}

# ---------------------------------------------------------------------------
# Backups
#
# Weekly snapshot of the root volume. Incremental, so after the first one you
# are paying for the delta, not 150 GB a week.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name_prefix        = "dcs-dlm-"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "snapshots" {
  description        = "Daily DCS server root volume snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Project = "dcs-server"
    }

    schedule {
      name = "daily"

      create_rule {
        # 21:00 UTC = 02:30 IST, comfortably after any game night.
        #
        # Daily rather than weekly because the marginal cost is about $1/month:
        # the first snapshot of a ~72 GB volume dominates the bill and every
        # one after it stores only changed blocks, and a DCS install barely
        # changes day to day. Losing a week of campaign progress to a volume
        # failure would cost far more than that.
        cron_expression = "cron(0 21 * * ? *)"
      }

      retain_rule {
        count = var.snapshot_retain_count
      }

      tags_to_add = {
        SnapshotCreator = "dlm"
      }

      copy_tags = true
    }
  }
}
