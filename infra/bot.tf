# ---------------------------------------------------------------------------
# Discord control bot
#
# /dcs start | stop | status, callable by your friends without any of them
# having an AWS account. Runs entirely inside the Lambda free tier.
#
# Set var.discord_public_key to deploy it; leave it empty and the whole bot is
# skipped (you can still start the instance from the console or CLI).
#
# Run bot\build.ps1 before `terraform apply` -- it vendors PyNaCl for the Lambda
# runtime into bot\build\.
# ---------------------------------------------------------------------------

locals {
  deploy_bot = var.discord_public_key != ""
}

data "archive_file" "bot" {
  count = local.deploy_bot ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/../bot/build"
  output_path = "${path.module}/.build/bot.zip"
}

data "aws_iam_policy_document" "bot_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bot" {
  count = local.deploy_bot ? 1 : 0

  provider = aws.bot

  name_prefix        = "dcs-bot-"
  assume_role_policy = data.aws_iam_policy_document.bot_assume.json
}

data "aws_iam_policy_document" "bot" {
  statement {
    sid       = "ControlTheServer"
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.dcs.id}"]
  }

  # DescribeInstances does not support resource-level permissions; "*" is the
  # only thing AWS accepts here. It is read-only.
  statement {
    sid       = "ReadState"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadPlayerCount"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/dcs/*"]
  }

  # /dcs restart bounces DCS_server.exe in-guest rather than rebooting the box.
  # Scoped to this one instance and this one AWS-owned document, so the bot
  # cannot run arbitrary commands anywhere else in the account.
  statement {
    sid     = "RestartDcsProcess"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.dcs.id}",
      "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunPowerShellScript",
    ]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.bot_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.server_name}-bot:*"]
  }
}

resource "aws_iam_role_policy" "bot" {
  count = local.deploy_bot ? 1 : 0

  provider = aws.bot

  name_prefix = "dcs-bot-"
  role        = aws_iam_role.bot[0].id
  policy      = data.aws_iam_policy_document.bot.json
}

# Created explicitly so retention is bounded. Lambda's implicit log group
# defaults to "never expire", which quietly accrues cost forever.
resource "aws_cloudwatch_log_group" "bot" {
  count = local.deploy_bot ? 1 : 0

  provider = aws.bot

  name              = "/aws/lambda/${var.server_name}-bot"
  retention_in_days = 14
}

resource "aws_lambda_function" "bot" {
  count = local.deploy_bot ? 1 : 0

  provider = aws.bot

  function_name = "${var.server_name}-bot"
  role          = aws_iam_role.bot[0].arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  architectures = ["x86_64"] # must match the wheel platform in bot\build.ps1

  filename         = data.archive_file.bot[0].output_path
  source_code_hash = data.archive_file.bot[0].output_base64sha256

  # Discord hangs up at 3s. StartInstances returns in well under 1s; this
  # timeout only exists to bound a pathological AWS API stall.
  timeout     = 10
  memory_size = 256

  environment {
    variables = {
      INSTANCE_ID        = aws_instance.dcs.id
      DISCORD_PUBLIC_KEY = var.discord_public_key
      ALLOWED_GUILD_ID   = var.discord_guild_id
      ALLOWED_ROLE_ID    = var.discord_role_id
      PLAYER_PARAM       = "/dcs/playercount"
      QUEUED_PARAM       = "/dcs/queued-mission"
      SERVER_HOST        = aws_eip.dcs.public_ip
      DCS_PORT           = tostring(var.dcs_port)

      # /dcs status prefers this over the SSM parameter: the board publisher
      # rewrites it every ~15s where the watchdog only refreshes SSM every 5
      # minutes, and it carries the roster, FPS, uptime and zone balance too.
      # Falls back to SSM automatically when empty or unreachable.
      BOARD_URL = var.board_url != "" ? var.board_url : "https://${aws_cloudfront_distribution.board.domain_name}/data"


      # The Lambda runs in var.bot_region but the instance lives in var.region,
      # so boto3 must be pointed explicitly -- its default would be the
      # Lambda's own region and every call would 404 on a missing instance.
      TARGET_REGION = var.region
    }
  }

  depends_on = [aws_cloudwatch_log_group.bot]

  lifecycle {
    # Terraform zips bot/build/, not bot/handler.py. Editing the handler without
    # re-running build.ps1 therefore deploys STALE code silently -- the symptom
    # is Discord replying "Unknown command" for a subcommand that plainly exists
    # in the source. Caught exactly that with /dcs add-mission. Fail the plan
    # instead of shipping the wrong bytes.
    precondition {
      condition     = filesha256("${path.module}/../bot/handler.py") == filesha256("${path.module}/../bot/build/handler.py")
      error_message = "bot/build/handler.py is stale. Run bot\\build.ps1 before applying."
    }
  }
}

# auth_type NONE is correct and required: Discord signs each request with
# Ed25519 and cannot present SigV4 credentials. The handler rejects anything
# whose signature does not verify -- that check is the only thing standing
# between this URL and anyone on the internet starting your instance.
# ---------------------------------------------------------------------------
# Public endpoint: API Gateway HTTP API, NOT a Lambda Function URL.
#
# Function URLs do not work in this account. A URL with authorization_type
# "NONE" and a resource policy granting Principal "*" on lambda:InvokeFunctionUrl
# still returns:
#   403 {"Message":"Forbidden. For troubleshooting Function URL authorization..."}
# with no log stream ever created -- the request never reaches the function.
# Confirmed not to be an Organizations SCP (the account is standalone).
#
# The pre-existing arma3-discord bot in this same account and region shows the
# same fingerprint: a leftover FunctionURLAllowPublicAccess statement, no URL
# config, and an API Gateway in front. So this pivot is the proven path here,
# not a workaround invented on the spot.
#
# Payload format 2.0 gives the handler the same event shape a Function URL
# would (lowercased headers, `body`, `isBase64Encoded`), so handler.py needs
# no changes.
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "bot" {
  count = local.deploy_bot ? 1 : 0

  provider = aws.bot

  name          = "${var.server_name}-bot"
  protocol_type = "HTTP"
  description   = "Discord interactions endpoint for the DCS server bot"
}

resource "aws_apigatewayv2_integration" "bot" {
  count = local.deploy_bot ? 1 : 0

  provider = aws.bot

  api_id                 = aws_apigatewayv2_api.bot[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.bot[0].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "bot" {
  count = local.deploy_bot ? 1 : 0

  provider = aws.bot

  api_id    = aws_apigatewayv2_api.bot[0].id
  route_key = "POST /"
  target    = "integrations/${aws_apigatewayv2_integration.bot[0].id}"
}

resource "aws_apigatewayv2_stage" "bot" {
  count = local.deploy_bot ? 1 : 0

  provider = aws.bot

  api_id      = aws_apigatewayv2_api.bot[0].id
  name        = "$default"
  auto_deploy = true
}

# Reaching the endpoint is public; doing anything with it is not. Every request
# is Ed25519-verified in verify_signature() before a single AWS call is made.
resource "aws_lambda_permission" "bot_api" {
  count = local.deploy_bot ? 1 : 0

  provider = aws.bot

  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bot[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.bot[0].execution_arn}/*/*"
}
