variable "cluster_name" {
  type = string
}

variable "github_repo" {
  description = "org/repo — used for tagging/reference only; the trust policy itself uses oidc_sub_claim_prefix"
  type        = string
}

variable "oidc_sub_claim_prefix" {
  description = <<-EOT
    The real 'repo:...' prefix GitHub puts in its OIDC sub claim for this
    repo. Confirmed via:
      gh api repos/OWNER/REPO/actions/oidc/customization/sub
    If that call returns "use_immutable_subject": true, this is NOT
    "repo:owner/repo" - it includes numeric IDs, e.g.
    "repo:owner@12345/repo@67890". Check before trusting the plain form.
  EOT
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
