# Bootstrap state lives in the fleet's shared state bucket under its own
# key — the bootstrapped IAM (executor role, policies, access entry) and the
# executor's ECR repositories are ALL accounted for here, durably, not in a
# local terraform.tfstate on whoever ran it. The backend is configured at
# init time (backend blocks can't interpolate variables):
#
#   terraform -chdir=bootstrap init \
#     -backend-config=bucket=namazu-cloud-instance \
#     -backend-config=key=bootstrap/namazu-cloud-addon-dank-studios.tfstate \
#     -backend-config=region=us-east-1
#
# scripts/go-live.sh drives exactly that. CI NEVER inits with a backend
# (validate.yml uses -backend=false) and NEVER applies this root: the apply
# requires the operator's ambient AWS creds AND their own cluster access —
# see rbac.tf. Nothing else is allowed to mint this fork's authority.
terraform {
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.19.0, < 3.0.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }
}
