# --------------------------------------------------------------------------
# The Kubernetes half of the executor identity — managed HERE, in the same
# manual-only apply as the access entry that binds it (replaces the old
# apply-once rbac.yaml). The provider authenticates as WHOEVER RUNS THE
# APPLY (no --role-arn: the ambient AWS identity's own cluster access, i.e.
# an operator with an access entry on the tenant cluster). That is the
# forcing function: CI cannot apply this root, so CI cannot grant itself
# in-cluster power. The executor role is the SUBJECT of these rules, never
# the identity that reconciles them.
#
# Cluster-side permissions are versioned here (reviewed via PR), reconciled
# on every manual apply, and never drift silently the way an apply-once
# manifest would. Forks: extend the rules below with what YOUR addons create
# (the Dank Studios fork adds the Karpenter tier objects and storageclasses).
# --------------------------------------------------------------------------

data "aws_eks_cluster" "cluster" {
  name = var.eks_cluster_name
}

locals {
  eks_exec_args = [
    "eks", "get-token",
    "--cluster-name", data.aws_eks_cluster.cluster.id,
    "--region", var.aws_region,
    # Deliberately NO --role-arn: the token must identify the operator
    # running the bootstrap (who has cluster access), not the executor role
    # being minted. The addon runner, by contrast, execs AS the executor
    # role via eks_cluster_role_arn — see main.tf's self-assume statement.
  ]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "${path.module}/../bin/aws-eks-get-token-retry"
    args        = local.eks_exec_args
  }
}

provider "kubectl" {
  load_config_file = false

  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "${path.module}/../bin/aws-eks-get-token-retry"
    args        = local.eks_exec_args
  }
}

resource "kubernetes_cluster_role" "addons_executor" {
  metadata {
    name = "addons-executor"
    labels = {
      managed_by = "terraform"
      repo       = "${var.github_organization}/${var.repository}"
      component  = "addons-executor-bootstrap"
    }
  }

  # Namespaced CRUD for addon resources (kubectl_manifest targets, helm
  # releases, etc. across tenant namespaces).
  rule {
    api_groups = ["", "apps", "batch", "networking.k8s.io", "rbac.authorization.k8s.io",
    "autoscaling", "policy", "extensions", "kustomize.toolkit.fluxcd.io"]
    resources = ["*"]
    verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Minimal cluster-scope needs (kubectl/provider layering: namespaces,
  # nodes list/watch, API discovery).
  rule {
    api_groups = [""]
    resources  = ["namespaces", "nodes", "persistentvolumes"]
    verbs      = ["get", "list", "watch"]
  }

  # CRDs — addons may define or consume them.
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions/status"]
    verbs      = ["update", "patch"]
  }
}

resource "kubernetes_cluster_role_binding" "addons_executor" {
  metadata {
    name = "addons-executor"
    labels = {
      managed_by = "terraform"
      repo       = "${var.github_organization}/${var.repository}"
      component  = "addons-executor-bootstrap"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.addons_executor.metadata[0].name
  }

  # The GROUP the EKS access entry (main.tf) puts the executor identity in.
  subject {
    kind      = "Group"
    name      = var.kubernetes_group
    api_group = "rbac.authorization.k8s.io"
  }
}
