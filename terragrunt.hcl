locals {
  aws_region = "us-east-1"
}

# Terragrunt bootstraps its own S3 backend bucket + DynamoDB lock table
# on first `terragrunt init` — no separate bootstrap.sh, no placeholder
# bucket name to remember to update. The account ID is pulled live via
# get_aws_account_id(), so the bucket name is unique without anyone
# having to hand-edit it first.
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "eks-gitops-dr-drill-tfstate-${get_aws_account_id()}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.aws_region
    encrypt        = true
    dynamodb_table = "eks-gitops-dr-drill-tf-locks"
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"

  default_tags {
    tags = {
      Project   = "eks-gitops-dr-drill"
      ManagedBy = "terragrunt"
    }
  }
}
EOF
}

inputs = {
  aws_region = local.aws_region
}
