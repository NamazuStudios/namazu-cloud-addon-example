# The Kubernetes half of the executor identity — Terraform-managed, reading
# bootstrap/rbac.yaml FROM DISK: the YAML stays the readable, PR-reviewed
# source of truth while the objects live in Terraform state (created,
# reconciled on every apply, and DELETED with `terraform destroy` — the
# addon setup's own teardown).
#
# The kubectl provider authenticates as WHOEVER RUNS THE APPLY —
# deliberately NO --role-arn, so the token identifies the operator (who
# must already hold cluster access). That is the forcing function: CI
# cannot apply this root, so CI cannot grant itself in-cluster power.
# The executor role is the SUBJECT of these rules, never the identity
# that reconciles them.

data "aws_eks_cluster" "cluster" {
  name = var.eks_cluster_name
}

provider "kubectl" {
  load_config_file       = false
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "${path.module}/../bin/aws-eks-get-token-retry"
    args = [
      "eks", "get-token",
      "--cluster-name", data.aws_eks_cluster.cluster.id,
      "--region", var.aws_region,
      # Deliberately NO --role-arn: the operator's own identity applies.
    ]
  }
}

locals {
  # rbac.yaml carries TWO documents (ClusterRole, ClusterRoleBinding)
  # separated by a `---` line; kubectl_manifest takes one manifest per
  # resource, so split on the separator and key by kind.
  rbac_docs = {
    for doc in [for raw in split("\n---\n", file("${path.module}/rbac.yaml")) :
    yamldecode(trimspace(raw))] : doc["kind"] => yamlencode(doc)
  }
}

resource "kubectl_manifest" "rbac" {
  for_each  = local.rbac_docs
  yaml_body = each.value
}
