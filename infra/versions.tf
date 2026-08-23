terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "dcs-server"
      ManagedBy = "terraform"
    }
  }
}

# The Discord bot lives in a different region to the game server, because
# Lambda Function URLs are NOT available in ap-south-2 (Hyderabad):
# CreateFunctionUrlConfig there returns
#   AccessDeniedException: Unable to determine service/operation name to be authorized
# which is how Lambda reports an operation the regional endpoint doesn't
# implement. Verified against the raw CLI, so it is not a Terraform artefact.
#
# Cross-region control is harmless -- the Lambda just points its EC2 and SSM
# clients at var.region. Latency on a start/stop call is irrelevant.
provider "aws" {
  alias  = "bot"
  region = var.bot_region

  default_tags {
    tags = {
      Project   = "dcs-server"
      ManagedBy = "terraform"
    }
  }
}
