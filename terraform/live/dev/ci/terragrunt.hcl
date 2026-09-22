include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/ci"
}

inputs = {
  cluster_name = "eks-gitops-dr-drill-dev"
  github_repo  = "gkoufie1/eks-gitops-dr-drill"

  # Confirmed via: gh api repos/gkoufie1/eks-gitops-dr-drill/actions/oidc/customization/sub
  # This repo has immutable OIDC subject claims enabled - the plain
  # "repo:owner/repo" form does NOT appear in the real token.
  oidc_sub_claim_prefix = "repo:gkoufie1@131033143/eks-gitops-dr-drill@1380478109"

  tags = {
    Environment = "dev"
  }
}
