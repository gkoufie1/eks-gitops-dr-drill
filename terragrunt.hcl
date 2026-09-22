locals {
  # Where the actual VPC/EKS/NAT resources get created. us-east-1 hit the
  # account's default 5-VPCs-per-region limit (3 leftover course VPCs, a
  # main-vpc, and the account default) — rather than touch existing
  # resources or wait on a quota increase, this project deploys to
  # us-east-2 instead.
  aws_region = "us-east-2"

  # Where Terraform's own state bucket lives — independent of aws_region
  # above. It was already bootstrapped here before the region switch, and
  # a state bucket's region never needs to match its resources' region,
  # so it stays put rather than creating a second one.
  state_region = "us-east-1"
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
    region         = local.state_region
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
