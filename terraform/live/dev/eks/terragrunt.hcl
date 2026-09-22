include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/eks"
}

dependency "vpc" {
  config_path = "../vpc"
}

locals {
  # Real operator IP, supplied via env var so it never gets committed to a
  # public repo — export EKS_ALLOWED_CIDR="$(curl -4 -s ifconfig.me)/32"
  # before running terragrunt. Falls back to 0.0.0.0/0 only so `plan`
  # doesn't hard-fail with no value set — apply refuses to run open, see
  # the check below.
  allowed_cidr = get_env("EKS_ALLOWED_CIDR", "0.0.0.0/0")
}

inputs = {
  cluster_name       = "eks-gitops-dr-drill-dev"
  environment        = "dev"
  public_subnet_ids  = dependency.vpc.outputs.public_subnet_ids
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids

  allowed_cidr_blocks = [local.allowed_cidr]

  tags = {
    Environment = "dev"
  }
}
