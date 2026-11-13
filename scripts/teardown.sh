#!/usr/bin/env bash
# teardown.sh — the OPERATOR full teardown for this fork's addon setup.
# ORDER MATTERS: addon states must be destroyed BEFORE the bootstrap
# (destroying the executor role first strands the addon states).
set -euo pipefail
say() { printf '%s\n' "$*"; }
die() { printf '  ✗ %s\n' "$*" >&2; exit 1; }
prompt() { local __var="$1" q="$2" d="$3" a; read -r -p "  $q [$d] " a || die "aborted (EOF)"; printf -v "$__var" '%s' "${a:-$d}"; }

say "== Full teardown for this fork's addon setup =="
prompt AWS_REGION       "AWS region" "us-east-1"
prompt EKS_CLUSTER_NAME "EKS cluster name" ""
[ -n "$EKS_CLUSTER_NAME" ] || die "cluster name required"
say "  STEP 1 - addon states: run the 'teardown-addons' workflow FIRST"
say "    (Actions -> teardown-addons -> Run workflow -> confirm: destroy-addons)"
read -r -p "  Type 'DESTROY' to run terraform destroy on bootstrap/ (IAM role, policies, access entry, ClusterRole/Binding): " CONFIRM
[ "$CONFIRM" = "DESTROY" ] || die "aborted before destroy"
say "  Run terraform destroy in bootstrap/ with the same -var values as go-live."
say "  (kept manual here so the operator sees the destroy plan in full)"
say "Done - the Terraform-managed ClusterRole/Binding are deleted from the cluster with your identity."
