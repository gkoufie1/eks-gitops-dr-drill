include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/ci"
}

inputs = {
  cluster_name = "eks-gitops-dr-drill-dev"
  github_repo  = "gkoufie1/eks-gitops-dr-drill"

  tags = {
    Environment = "dev"
  }
}
