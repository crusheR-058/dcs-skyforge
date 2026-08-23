# ---------------------------------------------------------------------------
# Game nights and the patch window
#
# Two ops problems, both solved with EventBridge Scheduler rather than code:
#
#   1. Somebody has to remember to run /dcs start. On a scheduled night that
#      is pure friction -- the first person to arrive waits 3-5 minutes for a
#      cold boot while everyone else trickles in.
#
#   2. Patch day locks everyone out. DCS refuses a client on a different build,
#      so the morning after an ED release nobody can join until the server
#      updates, and the symptom is an unhelpful "connection failed".
#
# Deliberately NO Lambda here. EventBridge Scheduler's universal targets can
# call ec2:StartInstances and ssm:SendCommand directly, so the whole thing is
# two IAM statements and four schedules with nothing to deploy, version or
# debug.
#
# Nothing here needs a matching "stop" rule: the in-guest watchdog already
# stops an empty server, and automation.tf keeps the nightly force-stop as a
# backstop. A game night nobody turns up to therefore costs one grace period
# of runtime -- roughly $0.40 -- and stops itself.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_ops" {
  statement {
    sid       = "StartForGameNight"
    actions   = ["ec2:StartInstances"]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.dcs.id}"]
  }

  # Scoped to the one document and the one instance. SendCommand with
  # AWS-RunPowerShellScript is arbitrary code execution as SYSTEM, so this is
  # not a permission to hand out loosely.
  statement {
    sid     = "RunMaintenanceCommand"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.dcs.id}",
      "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunPowerShellScript",
    ]
  }
}

resource "aws_iam_role_policy" "scheduler_ops" {
  name_prefix = "dcs-scheduler-ops-"
  role        = aws_iam_role.scheduler.id
  policy      = data.aws_iam_policy_document.scheduler_ops.json
}

# ---------------------------------------------------------------------------
# Game nights
#
# One schedule per entry in var.game_nights. The server announces itself in
# Discord once it is genuinely joinable (server\announce.ps1) rather than when
# the instance starts -- those are several minutes apart, and announcing the
# wrong one teaches people to ignore the message.
# ---------------------------------------------------------------------------

resource "aws_scheduler_schedule" "game_night" {
  for_each = var.enable_game_nights ? var.game_nights : {}

  name        = "${var.server_name}-gamenight-${each.key}"
  description = "Pre-start the DCS server for ${each.key} game night"
  group_name  = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = each.value
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = [aws_instance.dcs.id]
    })

    # Starting an already-running instance is a harmless no-op, and a missed
    # game night start is not worth paging anyone over -- /dcs start still
    # works. One retry covers a transient API blip.
    retry_policy {
      maximum_retry_attempts = 1
    }
  }
}

# ---------------------------------------------------------------------------
# Weekly patch window
#
# Two schedules rather than one, because SendCommand needs the SSM agent
# already registered: the instance boots at var.maintenance_boot_cron and the
# update fires var.maintenance_gap_minutes later.
#
# The gap is generous on purpose. A cold Windows boot to SSM-online is about
# three minutes; a command sent early fails outright rather than queueing, and
# the whole point of this is that nobody is watching.
# ---------------------------------------------------------------------------

resource "aws_scheduler_schedule" "maintenance_boot" {
  count = var.enable_auto_update ? 1 : 0

  name        = "${var.server_name}-maintenance-boot"
  description = "Start the DCS server for its weekly patch window"
  group_name  = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.maintenance_boot_cron
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = [aws_instance.dcs.id]
    })

    retry_policy {
      maximum_retry_attempts = 2
    }
  }
}

resource "aws_scheduler_schedule" "maintenance_update" {
  count = var.enable_auto_update ? 1 : 0

  name        = "${var.server_name}-maintenance-update"
  description = "Run the DCS updater, then let the idle watchdog stop the box"
  group_name  = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.maintenance_update_cron
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ssm:sendCommand"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      DocumentName = "AWS-RunPowerShellScript"
      InstanceIds  = [aws_instance.dcs.id]
      Comment      = "Weekly DCS patch window"
      # update-dcs.ps1 refuses if anyone is connected and reports the outcome
      # to the Discord webhook either way, so this fires blind by design.
      Parameters = {
        commands = ["& C:\\dcs-state\\update-dcs.ps1 -Reason scheduled"]
      }
    })

    # If the instance is not registered with SSM yet the call fails outright.
    # Retries cover a slow boot; the 15-minute window is well inside the
    # watchdog's first-join grace period, so a retry cannot outlive the box.
    retry_policy {
      maximum_retry_attempts       = 5
      maximum_event_age_in_seconds = 900
    }
  }

  depends_on = [aws_scheduler_schedule.maintenance_boot]
}
