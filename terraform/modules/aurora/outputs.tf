output "cluster_endpoint" {
  description = "Writer endpoint"
  value       = aws_rds_cluster.main.endpoint
}

output "reader_endpoint" {
  value = aws_rds_cluster.main.reader_endpoint
}

output "cluster_resource_id" {
  description = "The DbiResourceId used to build IAM auth ARNs"
  value       = aws_rds_cluster.main.cluster_resource_id
}

output "database_name" {
  value = aws_rds_cluster.main.database_name
}

output "master_username" {
  value = aws_rds_cluster.main.master_username
}

output "master_user_secret_arn" {
  description = "Secrets Manager ARN holding the AWS-generated master password — needed once, for the manual bootstrap step that creates the IAM-mapped database user"
  value       = aws_rds_cluster.main.master_user_secret[0].secret_arn
}

output "app_db_role_arn" {
  description = "IRSA role the app's service account assumes to connect via rds-db:connect"
  value       = aws_iam_role.app_db_access.arn
}

output "iam_db_username" {
  value = var.iam_db_username
}

output "security_group_id" {
  value = aws_security_group.aurora.id
}
