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

output "ecr_registry" {
  description = "The ECR registry host for this account/region — the docker login target for the tenant CI push wiring."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_repository_urls" {
  description = "Tenant ECR repository URLs by name — the values the tenant chart's image: flip and the CI push workflow point at."
  value       = { for name, repo in aws_ecr_repository.tenant : name => repo.repository_url }
}
