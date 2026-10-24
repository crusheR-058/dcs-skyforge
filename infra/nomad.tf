# ---------------------------------------------------------------------------
# Nomad: the voice AI on SRS 251.0 AM (source: the dcs-bob project)
# ---------------------------------------------------------------------------
#
# Its own inline policy, so it can be applied or removed without touching
# anything else, including the instance:
#
#   terraform plan  -target=aws_iam_role_policy.nomad
#   terraform apply -target=aws_iam_role_policy.nomad
#
# What Nomad calls, all from the instance role:
#   * Nova Lite through the APAC cross-region profile (home, ap-south-1) and the
#     US one (backup, us-east-1, used when the home region hangs);
#   * the fine-tuned router, an on-demand custom-model deployment in us-east-1;
#   * Transcribe streaming in ap-south-1, for pilots' voice calls. Speech-to-text
#     runs there, not on this box, because DCS needs both physical cores.

data "aws_iam_policy_document" "nomad" {
  statement {
    sid     = "NomadBedrock"
    actions = ["bedrock:InvokeModel"] # Converse is authorised as InvokeModel
    resources = concat([
      "arn:aws:bedrock:ap-south-1:${data.aws_caller_identity.current.account_id}:inference-profile/apac.amazon.nova-lite-v1:0",
      "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/us.amazon.nova-lite-v1:0",
      # A cross-region profile may serve the request from any region in its geography.
      "arn:aws:bedrock:*::foundation-model/amazon.nova-lite-v1:0",
    ], compact([var.nomad_router_deployment_arn, var.nomad_router_model_arn]))
  }

  # StartStreamTranscription has no resource-level permissions.
  statement {
    sid       = "NomadTranscribe"
    actions   = ["transcribe:StartStreamTranscription"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "nomad" {
  name_prefix = "dcs-nomad-"
  role        = aws_iam_role.instance.id
  policy      = data.aws_iam_policy_document.nomad.json
}
