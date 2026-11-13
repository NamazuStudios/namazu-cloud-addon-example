# The role ARN to bind into the fork's GitHub *variables* as
# ADDONS_EXECUTOR_ROLE_ARN (repo Settings → Secrets and variables → Actions →
# Variables). Workflows pass it to aws-actions/configure-aws-credentials.

output "executor_role_arn" {
  description = "This fork's executor role ARN (bind as ADDONS_EXECUTOR_ROLE_ARN)."
  value       = aws_iam_role.executor.arn
}

output "kubernetes_group" {
  description = "Kubernetes group the executor identity lands in; rbac.tf binds this group's ClusterRole (same apply)."
  value       = var.kubernetes_group
}


