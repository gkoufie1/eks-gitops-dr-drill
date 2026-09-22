variable "cluster_name" {
  description = "Name prefix, matches the EKS cluster name for consistency"
  type        = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr_block" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "oidc_provider_arn" {
  description = "The EKS cluster's OIDC provider ARN, for IRSA trust policy"
  type        = string
}

variable "oidc_provider_url" {
  description = "The EKS cluster's OIDC provider URL, for IRSA trust policy"
  type        = string
}

variable "app_namespace" {
  type    = string
  default = "apps"
}

variable "app_service_account" {
  type    = string
  default = "demo-app"
}

variable "database_name" {
  type    = string
  default = "drdrill"
}

variable "master_username" {
  type    = string
  default = "postgres"
}

variable "iam_db_username" {
  description = "The Postgres role the app connects as via IAM auth — created in the one-time bootstrap step, not by Terraform (Terraform can't run SQL)"
  type        = string
  default     = "app_iam_user"
}

variable "engine_version" {
  # 16.6 doesn't actually exist for aurora-postgresql (only 16.6-limitless
  # does) - confirmed the real available versions via
  # `aws rds describe-db-engine-versions` before picking this one.
  type    = string
  default = "16.9"
}

variable "min_capacity" {
  description = "Minimum Aurora Serverless v2 ACUs — 0.5 is the smallest AWS allows"
  type        = number
  default     = 0.5
}

variable "max_capacity" {
  type    = number
  default = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}
