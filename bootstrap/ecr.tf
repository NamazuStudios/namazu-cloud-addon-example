# --------------------------------------------------------------------------
# Tenant image registry (generic): ECR repositories in the same
# account/region as the cluster, so tenant images pull in-region via the
# node/IRSA role instead of cross-region GHCR through a pull secret.
#
# Default is EMPTY — forks set `ecr_repositories` (or wire it in their
# go-live run) to the images their tenants actually ship. The executor role
# needs NO ECR grants here: CI pushes (tenant-side wiring), nodes pull (their
# own role's IAM). The optional repository policy below only *adds* a pull
# grant for a named role.
#
# Digest-pin workflow carries over 1:1: IMMUTABLE tag mutability means a
# re-pushed tag is rejected outright — charts that pin by digest already
# push at distinct digests regardless; mutability just enforces it.
# --------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

resource "aws_ecr_repository" "tenant" {
  for_each = toset(var.ecr_repositories)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # AES256, not KMS: KMS-encrypted layers would make every node pull need
  # kms:Decrypt on the key; AES256 keeps the node-role IAM story unchanged.
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    ManagedBy = "terraform"
    Repo      = "${var.github_organization}/${var.repository}"
    Component = "addons-executor-bootstrap"
  }
}

# Lifecycle discipline with digest pinning in mind: a running deployment
# (and any future node) still pulls the currently-pinned digest, and a
# rollback points at an older one — so tagged images are kept well past the
# pin's practical horizon, and only untagged debris expires fast.
resource "aws_ecr_lifecycle_policy" "tenant" {
  for_each = toset(var.ecr_repositories)

  repository = aws_ecr_repository.tenant[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged (e.g. IMMUTABLE-rejected overwrite debris) after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 20 tagged images (pinned digests + rollback headroom)"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}

# Optional explicit pull grant (e.g. the cluster's Karpenter node role).
# Empty by default: same-account pulls are governed by the pulling role's
# own IAM policy. Set it to hand the policy over here instead.
data "aws_iam_policy_document" "tenant_pull" {
  statement {
    sid    = "NodePull"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = var.ecr_pull_role_arns
    }
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
  }
}

resource "aws_ecr_repository_policy" "tenant_pull" {
  # Only when a pull role was named: an empty identifiers list is not a
  # valid principals block, and no instance means the document is never read.
  for_each = (length(var.ecr_pull_role_arns) > 0 && length(var.ecr_repositories) > 0) ? toset(var.ecr_repositories) : toset([])

  repository = aws_ecr_repository.tenant[each.key].name
  policy     = data.aws_iam_policy_document.tenant_pull.json
}
