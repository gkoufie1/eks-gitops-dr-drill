variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region the cluster is deployed in"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for the EKS cluster API server ENIs"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs Fargate pods run in"
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the EKS public API endpoint — set to your own IP/32, never left at 0.0.0.0/0"
  type        = list(string)
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
