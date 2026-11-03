variable "github_organization" {
  description = "The GitHub org owning the addon-family repos (trust binding)."
  type        = string
  default     = "NamazuStudios"
}

variable "repository" {
  description = "This fork's repo name (trust binding: repo:<org>/<name>)."
  type        = string
}

variable "environment" {
  description = "GitHub environment the runs are pinned to (trust binding)."
  type        = string
  default     = "prod"
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN; empty = create one here."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "Region of the cluster and the state bucket."
  type        = string
}

variable "eks_cluster_name" {
  description = "Cluster the access entry is minted against."
  type        = string
}

variable "state_bucket" {
  description = "The tenant baseline's state bucket (the same bucket addons use)."
  type        = string
}

variable "kubernetes_group" {
  description = "Kubernetes group the access entry puts the executor identity in (rbac.tf binds this group's ClusterRole)."
  type        = string
  default     = "addons-executor"
}

variable "feature_policy_json" {
  description = "Feature grants as JSON (preferred over file detection); empty = read ../iam.policy.json, tolerate its absence."
  type        = string
  default     = ""
}

variable "role_name" {
  description = "Override the executor role's name; default derives from the repo."
  type        = string
  default     = ""
}

variable "ecr_repositories" {
  description = "Tenant ECR repositories to create in var.aws_region — the in-region pull home for images currently riding GHCR through a pull secret. Empty (default) = none."
  type        = list(string)
  default     = []
}

variable "ecr_pull_role_arns" {
  description = "Role ARNs granted ECR pull on those repositories (e.g. the cluster's Karpenter node role). Empty = no repository policy; same-account pulls are then governed by the pulling role's own IAM policy alone."
  type        = list(string)
  default     = []
}
