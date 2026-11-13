# ONE-TIME bootstrap: mints this fork's least-privilege executor role.
#
# Run once by an admin with a management-role:
#   terraform -chdir=bootstrap init
#   terraform -chdir=bootstrap apply \
#     -var=github_organization=NamazuStudios \
#     -var=repository=namazu-cloud-addon-<org-slug> \
#     -var=environment=prod \
#     -var=aws_region=<region> \
#     -var=eks_cluster_name=<cluster> \
#     -var=state_bucket=<backend bucket>
# then bind the eventual role ARN in the fork's GitHub variables as
# ADDONS_EXECUTOR_ROLE_ARN (see README) — or just run scripts/go-live.sh,
# which drives all of it interactively.

locals {
  trust_subject = "repo:${var.github_organization}/${var.repository}:"
  create_oidc   = var.github_oidc_provider_arn == ""
  role_name     = var.role_name != "" ? var.role_name : "${var.repository}-executor"
  # The addon repo's committed least-privilege request (iam.policy.json at the
  # fork root). `try` keeps a fresh fork (example file, not yet renamed)
  # bootable with an EMPTY feature policy instead of a hard failure.
  feature_policy_json = var.feature_policy_json != "" ? var.feature_policy_json : try(file("${path.root}/../iam.policy.json"), "")
  # Accounting tags stamped on everything this root mints (role, policies,
  # access entry, ECR repos) — `aws iam list-roles` / tag editors can answer
  # "what exists because of this repo" without this statefile.
  bootstrap_tags = {
    ManagedBy = "terraform"
    Repo      = "${var.github_organization}/${var.repository}"
    Component = "addons-executor-bootstrap"
  }
  # The role's own ARN, derived from its (known) name instead of the resource
  # attribute — the trust policy needs the role as a principal and the role
  # needs the trust policy, which is a cycle through the resource attribute.
  # Assumes the default path // for the role (role_name has no path prefix).
  executor_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.role_name}"
}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.create_oidc ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"

  # GitHub's static root CAs; token-verification no longer requires them on
  # modern IAM but retaining the list keeps older accounts valid.
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  oidc_provider_arn = var.github_oidc_provider_arn != "" ? var.github_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.trust_subject}environment:${var.environment}",
        "${local.trust_subject}ref:refs/heads/main",
      ]
    }
  }

  statement {
    # Self-assume: the addon runner execs `aws eks get-token --role-arn
    # <eks_cluster_role_arn>` from within a session that IS this role (CI
    # assumes it via OIDC), and the EKS exec plugin assumes the role before
    # presigning its token. Without this statement that self-assume is
    # denied (the web-identity statement above can't authorize it), and
    # every addon's cluster-side apply dies at the provider.
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [local.executor_role_arn]
    }
  }
}

resource "aws_iam_role" "executor" {
  name                 = local.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600

  # Accounting: this role is minted by THIS root and must be findable in IAM
  # listings by who/what created it (see README "What bootstrap creates").
  tags = local.bootstrap_tags
}

# --------------------------------------------------------------------------
# Base grant — every executor role, regardless of feature (plan §7):
#   read the tenant tree; write/delete ONLY addon keys (+ locks);
#   describe the cluster. Never: baseline terraform.tfstate writes.
# --------------------------------------------------------------------------

data "aws_iam_policy_document" "base" {
  statement {
    sid    = "TenantTreeRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketLocation",
    ]
    resources = ["arn:aws:s3:::${var.state_bucket}/*"]
  }

  statement {
    sid       = "TenantTreeList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
    condition {
      test     = "StringEquals"
      variable = "s3:prefix"
      values   = ["tenants/"]
    }
  }

  statement {
    sid    = "AddonKeysWrite"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket}/tenants/*/addon_*.tfstate",
      "arn:aws:s3:::${var.state_bucket}/tenants/*/addon_*.tflock",
    ]
  }

  statement {
    sid       = "EksDescribe"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster", "eks:DescribeAddonVersions"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "base" {
  name   = "${var.repository}-executor-base"
  policy = data.aws_iam_policy_document.base.json

  tags = local.bootstrap_tags
}

# Feature grants: the addon's committed policy, attached as a separate inline
# role policy only when it is non-empty. Bootstrap never fails for a fresh
# fork that hasn't renamed iam.policy.json.example yet.
resource "aws_iam_role_policy" "feature" {
  count  = local.feature_policy_json != "" ? 1 : 0
  name   = "feature"
  role   = aws_iam_role.executor.id
  policy = local.feature_policy_json
}

resource "aws_iam_role_policy_attachment" "base" {
  role       = aws_iam_role.executor.name
  policy_arn = aws_iam_policy.base.arn
}

# --------------------------------------------------------------------------
# Cluster admission: EKS access entry bound to the addons-executor Kubernetes
# group. The GROUP's actual verbs live in rbac.yaml (apply once by an admin),
# so cluster-side permissions are versioned outside AWS.
# --------------------------------------------------------------------------

resource "aws_eks_access_entry" "executor" {
  cluster_name      = var.eks_cluster_name
  principal_arn     = aws_iam_role.executor.arn
  kubernetes_groups = [var.kubernetes_group]

  tags = local.bootstrap_tags
}
