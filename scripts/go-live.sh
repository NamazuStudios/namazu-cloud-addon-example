#!/usr/bin/env bash
# go-live.sh — interactive, bookkept bootstrap of this fork's executor infra.
#
# WHAT THIS ROOT CREATES (one manual, operator-run apply):
#   - the executor IAM role + base/feature policies        (main.tf)
#   - the EKS access entry binding it to the addons-executor group (main.tf)
#   - the addons-executor ClusterRole + ClusterRoleBinding (rbac.tf)
#   - the tenant ECR repositories + policies + lifecycle   (ecr.tf, if any)
#   - state in the shared S3 bucket under bootstrap/<repo>.tfstate
#
# CI NEVER RUNS THIS. validate.yml only fmt/validates; apply requires the
# operator's ambient AWS creds AND their own cluster access (rbac.tf's
# provider authenticates as whoever runs it — no --role-arn). The executor
# role is the subject of the RBAC, never the identity that mints it.
#
# Every mutating step below asks; every step prints what it did. Re-runnable:
# terraform reconciles; gh wiring overwrites only with confirmation.
set -euo pipefail

# ---------------------------------------------------------------- helpers --
BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
DONE=(); SKIPPED=(); NEXT=()

say()  { printf '%s\n' "$*"; }
hdr()  { say; say "${BOLD}== $* ==${RST}"; }
ok()   { say "${GRN}  ✓${RST} $*"; DONE+=("$*"); }
skip() { say "${YLW}  -${RST} $*"; SKIPPED+=("$*"); }
die()  { say "${RED}  ✗ $*${RST}" >&2; exit 1; }

confirm() { # confirm <question> [default y|n]
  local q="$1" d="${2:-n}" a
  while true; do
    read -r -p "  $q $([ "$d" = y ] && echo '[Y/n]' || echo '[y/N]') " a || die "aborted (EOF)"
    a="${a:-$d}"
    case "$a" in [Yy]|[Yy][Ee][Ss]) return 0 ;; [Nn]|[Nn][Oo]) return 1 ;; *) say "  (y/n)" ;; esac
  done
}
prompt() { # prompt <var> <question> <default>
  local __var="$1" q="$2" d="$3" a
  read -r -p "  $q [$d] " a || die "aborted (EOF)"
  printf -v "$__var" '%s' "${a:-$d}"
}
need() { command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"; }
csvarr() { jq -Rn --arg s "$1" '[ $s | split(",")[] | select(length>0) | gsub("^ +| +$";"") ]'; }

# -------------------------------------------------------------- preflight --
hdr "Preflight"
for c in terraform kubectl gh aws jq git; do need "$c"; done
ok "tools present (terraform $(terraform version -json 2>/dev/null | jq -r .terraform_version 2>/dev/null || echo '?'), kubectl, gh, aws, jq, git)"

say "  GitHub session:"
gh auth status 2>&1 | sed 's/^/    /'
confirm "GitHub auth above is you, with repo admin on the fork?" n || die "re-auth with 'gh auth login' first"

say "  AWS identity (the creds bootstrap will run under):"
AWS_IDENT_JSON="$(aws sts get-caller-identity --output json)" || die "ambient AWS creds unusable — export the admin credentials first"
say "    account: $(jq -r .Account <<<"$AWS_IDENT_JSON")"
say "    arn:     $(jq -r .Arn <<<"$AWS_IDENT_JSON")"

prompt AWS_REGION        "AWS region"                          "us-east-1"
prompt EKS_CLUSTER_NAME  "EKS cluster name (the tenants' cluster)" ""
[ -n "$EKS_CLUSTER_NAME" ] || die "cluster name required"
aws eks describe-cluster --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME" \
  --query 'cluster.{name:name,version:version,status:status}' --output table \
  || die "cannot describe cluster '$EKS_CLUSTER_NAME' with these creds"
ok "cluster reachable via AWS API"

say "  Cluster-plane access (rbac.tf's provider authenticates as THIS identity):"
confirm "Run 'aws eks update-kubeconfig' against $EKS_CLUSTER_NAME with the ambient identity?" y \
  && aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
for want in "create clusterroles" "create storageclasses" "create customresourcedefinitions"; do
  CAN="$(kubectl auth can-i $want 2>/dev/null || echo no)"
  [ "$CAN" = "yes" ] || die "ambient identity CANNOT '$want' on this cluster — the operator needs an access entry (the same bar the old 'kubectl apply -f bootstrap/rbac.yaml' had)"
  ok "cluster-plane: can $want"
done

# ------------------------------------------------------------------ vars --
hdr "Bootstrap variables"
ROOT_GIT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$ROOT_GIT"
prompt GITHUB_ORG       "GitHub org"                           "NamazuStudios"
prompt REPOSITORY       "Fork repo name"                       "$(basename "$ROOT_GIT")"
prompt ENVIRONMENT      "GitHub environment (trust binding)"   "prod"
prompt STATE_BUCKET     "S3 state bucket"                      "namazu-cloud-instance"
prompt BACKEND_KEY      "S3 state key (fork-distinct)"         "bootstrap/${REPOSITORY}.tfstate"
prompt KUBERNETES_GROUP "kubernetes group for the executor"    "addons-executor"
prompt ECR_REPOSITORIES "ECR repos, comma-separated (empty = none)"      ""
prompt ECR_PULL_ROLE_ARNS "ECR pull role ARNs, comma-separated (empty = no repo policy)" ""
ECR_LIST="$(csvarr "$ECR_REPOSITORIES")"
PULL_LIST="$(csvarr "$ECR_PULL_ROLE_ARNS")"

say
say "${BOLD}  Backend config (bookkeeping — where this root's state will live):${RST}"
say "    bucket = $STATE_BUCKET"
say "    key    = $BACKEND_KEY"
say "    region = $AWS_REGION   (encrypt = true)"
confirm "Initialize bootstrap against that backend?" y || die "backend wiring is the point — aborting"
TMPDIR_GL="$(mktemp -d)"; trap 'rm -rf "$TMPDIR_GL"' EXIT
printf 'region  = "%s"\nbucket  = "%s"\nkey     = "%s"\nencrypt = true\n' \
  "$AWS_REGION" "$STATE_BUCKET" "$BACKEND_KEY" > "$TMPDIR_GL/backend.hcl"
sed 's/^/    /' "$TMPDIR_GL/backend.hcl"

# ------------------------------------------------------------------ plan --
hdr "Terraform init + plan (bootstrap/)"
( cd bootstrap && terraform init -input=false -reconfigure \
    -backend-config="$TMPDIR_GL/backend.hcl" ) || die "terraform init failed"
PLAN_ARGS=( -var="github_organization=$GITHUB_ORG"  -var="repository=$REPOSITORY"
            -var="environment=$ENVIRONMENT"         -var="aws_region=$AWS_REGION"
            -var="eks_cluster_name=$EKS_CLUSTER_NAME" -var="state_bucket=$STATE_BUCKET"
            -var="kubernetes_group=$KUBERNETES_GROUP" -var="ecr_pull_role_arns=$PULL_LIST"
            -var="ecr_repositories=$ECR_LIST" )
( cd bootstrap && terraform plan -input=false -no-color "${PLAN_ARGS[@]}" ) \
  | tee "$TMPDIR_GL/plan.txt" || die "terraform plan failed"
say "  $(grep -E 'Plan: [0-9]+ to (add|change|destroy)' "$TMPDIR_GL/plan.txt" | tail -1 || echo 'no resource changes')"
confirm "The plan above is the full and only effect of this apply. Proceed?" n || die "aborted before apply"

# ------------------------------------------------------------------ apply --
hdr "Apply (operator-only: IAM + access entry + ClusterRole + ECR)"
say "  Typing confirmation required — this mints this fork's authority."
read -r -p "  Type 'APPLY' to run terraform apply: " CONFIRM
[ "$CONFIRM" = "APPLY" ] || die "aborted before apply"
( cd bootstrap && terraform apply -input=false -auto-approve -no-color "${PLAN_ARGS[@]}" ) \
  || die "terraform apply failed"
ok "terraform apply: IAM role/policies + access entry + ClusterRole/Binding + ECR repos (state: s3://$STATE_BUCKET/$BACKEND_KEY)"

OUT_JSON="$( (cd bootstrap && terraform output -json) )"
EXECUTOR_ARN="$(jq -r '.executor_role_arn.value' <<<"$OUT_JSON")"
K8S_GROUP="$(jq -r '.kubernetes_group.value' <<<"$OUT_JSON")"
ECR_REGISTRY="$(jq -r '.ecr_registry.value' <<<"$OUT_JSON")"
say
say "${BOLD}  What now exists because of this repo:${RST}"
say "    role:           $EXECUTOR_ARN"
say "    base policy:    ${REPOSITORY}-executor-base"
say "    feature policy: inline from iam.policy.json (or .example if unrenamed)"
say "    access entry:   $EKS_CLUSTER_NAME → group $K8S_GROUP"
say "    ClusterRole:    addons-executor (+ ClusterRoleBinding → group $K8S_GROUP)"
say "    ECR registry:   $ECR_REGISTRY"
jq -r '.ecr_repository_urls.value | to_entries[] | "    ECR repo:      \(.key) = \(.value)"' <<<"$OUT_JSON"
say "    state:          s3://$STATE_BUCKET/$BACKEND_KEY"

# ------------------------------------------------------------- gh wiring --
hdr "GitHub wiring (repo Variables / Secrets — each one confirmed)"
set_var() { # set_var <name> <value>
  local name="$1" val="$2" cur
  cur="$(gh variable list --json name,value --jq ".[] | select(.name==\"$name\") | .value" 2>/dev/null || true)"
  if [ "$cur" = "$val" ]; then skip "variable $name already matches"; return; fi
  [ -n "$cur" ] && say "  $name currently: $cur"
  confirm "Set repo variable $name?" y || { skip "variable $name left as-is"; return; }
  gh variable set "$name" --body "$val"
  ok "variable $name set"
}
set_var ADDONS_EXECUTOR_ROLE_ARN "$EXECUTOR_ARN"
set_var CLUSTER_NAME "$EKS_CLUSTER_NAME"
set_var EKS_ROLE_ARN "$EXECUTOR_ARN"
if confirm "Set repo secret ELEMENTS_GIT_TOKEN now (read-only token for the private addon clones — the runner clones the
         private addon repos with it, and without it real applies fail at the
         clone with 'Repository not found')?"; then
  read -rs -p "  paste token (input hidden): " GIT_TOKEN; say
  gh secret set ELEMENTS_GIT_TOKEN --body "$GIT_TOKEN"
  ok "secret ELEMENTS_GIT_TOKEN set"
else
  skip "ELEMENTS_GIT_TOKEN not set (real applies fail at the addon clone until it is)"
fi

# ---------------------------------------------------------------- verify --
hdr "Verification"
say "  self-assume probe (the addon runner execs get-token --role-arn AS the executor):"
if aws eks get-token --cluster-name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --role-arn "$EXECUTOR_ARN" >/dev/null 2>&1; then
  ok "self-assume token mint works (trust allows the role → itself)"
else
  say "${YLW}  ✗ self-assume FAILED — addon applies will die at their provider.${RST}"
  say "    check bootstrap/main.tf's self-assume statement landed (re-run the apply),"
  say "    and that these creds are the same account/partition as the role."
fi
if confirm "Trigger the sync workflow now (gh workflow run sync.yml) and watch it?"; then
  gh workflow run sync.yml --ref main
  sleep 5
  RUN="$(gh run list --workflow=sync.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
  gh run watch "$RUN" --exit-status || true
  gh run view "$RUN" | sed 's/^/    /'
  ok "sync workflow triggered + watched ($RUN)"
else
  skip "sync workflow not triggered (push to main or dispatch later)"
fi
if kubectl get clusterrole addons-executor >/dev/null 2>&1; then
  ok "ClusterRole addons-executor present"
else
  skip "ClusterRole addons-executor not visible — check the bootstrap apply output"
fi
if aws ecr describe-repositories --region "$AWS_REGION" \
     --repository-names $(tr ',' ' ' <<<"$ECR_REPOSITORIES") \
     --query 'repositories[].repositoryUri' --output table >/dev/null 2>&1; then
  ok "ECR repositories present"
else
  skip "ECR verify (describe) failed — check aws creds"
fi

# --------------------------------------------------------------- summary --
hdr "Summary"
say "  ${GRN}done:${RST}";    printf '    ✓ %s\n' "${DONE[@]:-(none)}"
say "  ${YLW}skipped:${RST}"; printf '    - %s\n' "${SKIPPED[@]:-(none)}"
say "  ${BOLD}next (tenant-side, tracked in the issues):${RST}"
NEXT+=("migrate tenant images off GHCR into the ECR repos and flip the charts' image/imageTag")
NEXT+=("give tenant CI a role that can push to ECR (and drop the GHCR pull secrets)")
NEXT+=("keep iam.policy.json's least-privilege request tight as the addon family grows")
printf '    → %s\n' "${NEXT[@]}"
say
say "Re-run me any time — terraform reconciles; wiring overwrites only with confirmation."
