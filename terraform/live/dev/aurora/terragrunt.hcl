include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/aurora"
}

dependency "vpc" {
  config_path = "../vpc"
}

dependency "eks" {
  config_path = "../eks"
}

inputs = {
  cluster_name        = "eks-gitops-dr-drill-dev"
  vpc_id              = dependency.vpc.outputs.vpc_id
  vpc_cidr_block      = dependency.vpc.outputs.vpc_cidr_block
  private_subnet_ids  = dependency.vpc.outputs.private_subnet_ids
  oidc_provider_arn   = dependency.eks.outputs.oidc_provider_arn
  oidc_provider_url   = dependency.eks.outputs.oidc_provider_url

  tags = {
    Environment = "dev"
  }
}
