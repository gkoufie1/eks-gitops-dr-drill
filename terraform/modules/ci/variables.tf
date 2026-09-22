variable "cluster_name" {
  type = string
}

variable "github_repo" {
  description = "org/repo — scopes the OIDC trust policy so only this repo's workflows can assume the role"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
