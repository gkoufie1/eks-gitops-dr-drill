include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/vpc"
}

inputs = {
  vpc_cidr     = "10.0.0.0/16"
  cluster_name = "eks-gitops-dr-drill-dev"
  tags = {
    Environment = "dev"
  }
}
