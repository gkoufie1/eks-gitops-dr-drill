include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/eks"
}

dependency "vpc" {
  config_path = "../vpc"
}

inputs = {
  cluster_name       = "eks-gitops-dr-drill-dev"
  environment        = "dev"
  public_subnet_ids  = dependency.vpc.outputs.public_subnet_ids
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids

  # Update before apply — run `curl ifconfig.me` and use YOUR_IP/32.
  # Left at 0.0.0.0/0 this is a real, avoidable finding, not a demo one.
  allowed_cidr_blocks = ["0.0.0.0/0"]

  tags = {
    Environment = "dev"
  }
}
