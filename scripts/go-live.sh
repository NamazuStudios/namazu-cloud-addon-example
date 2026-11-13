#!/usr/bin/env bash
# go-live.sh — interactive, bookkept bootstrap of THIS fork's executor infra.
#
# WHAT IT DOES (one manual, operator-run apply):
#   - the executor IAM role + base/feature policies        (bootstrap/main.tf,
#     feature grant = iam.policy.json at the fork root)
#   - the EKS access entry binding it to the addons-executor group
#   - the addons-executor ClusterRole + ClusterRoleBinding (rbac.yaml,
#     applied once per cluster by an admin — THIS script does it)
#   - state in s3://namazu-tenant-tfstate-production-308044622771-us-east-1/bootstrap/<repo>.tfstate
#   - GitHub repo Variables: ADDONS_EXECUTOR_ROLE_ARN, CLUSTER_NAME, EKS_ROLE_ARN
#   - verifies the tenants' baseline statefiles carry the facts the addons bind
#   - optionally triggers sync.yml and watches it
#
# CI NEVER RUNS THIS. validate.yml only fmt/validates; apply requires the
# operator's ambient AWS creds. Re-runnable: terraform reconciles; gh wiring
# overwrites only with confirmation.
set -euo pipefail

BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
DONE=(); SKIPPED=()
say() { printf '%s\n' "$*"; }
hdr() { say; say "${BOLD}== $* ==${RST}"; }
ok()  { say "${GRN}  ✓${RST} $*"; DONE+=("$*"); }
skip(){ say "${YLW}  -${RST} $*"; SKIPPED+=("$*"); }
die() { say "${RED}  ✗ $*${RST}" >&2; exit 1; }
confirm() { local q="$1" d="${2:-n}" a
  while true; do read -r -p "  $q $([ "$d" = y ] && echo '[Y/n]' || echo '[y/N]') " a || die "aborted (EOF)"
    a="${a:-$d}"; case "$a" in [Yy]|[Yy][Ee][Ss]) return 0 ;; [Nn]|[Nn][Oo]) return 1 ;; *) say "  (y/n)" ;; esac; done; }
prompt() { local __var="$1" q="$2" d="$3" a; read -r -p "  $q [$d] " a || die "aborted (EOF)"; printf -v "$__var" '%s' "${a:-$d}"; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command '$1' not on PATH"; }

hdr "Who is this fork for? (prompted — nothing about your org is hardcoded)"
prompt ORG      "GitHub org" "NamazuStudios"
prompt REPO     "This fork's repo name" "$(basename "$(pwd)")"
prompt ORG_ID   "The org's database unique id (feeds the audit tags + the private-addon check)" ""
[ -n "$ORG_ID" ] || die "org id required"
prompt TENANT_IDS "The tenant ids this fork installs addons for, space-separated (instance or workspace ids)" ""
TENANTS=()
for t in $TENANT_IDS; do
  case "$t" in
    tenants/*) TENANTS+=("$t") ;;
    *) TENANTS+=("<kind>/$(printf '%s' "$t")") ;;
  esac
done
say "  (a tenant id alone is ambiguous about its kind — prefix instances/ or
   sandboxes/ if you want the fact-check path exactly right; the runner's
   own applies pass the kind explicitly from the matrix)"

hdr "Preflight"
# Self-heal the exec bit (git mode-only changes do not refresh an already-checked-out file)
chmod +x bin/aws-eks-get-token-retry 2>/dev/null || true
# IAM policy documents must be printable ASCII — catch it before the apply does
if LC_ALL=C grep -q "[^[:print:][:space:]]" iam.policy.json 2>/dev/null; then
  die "iam.policy.json contains non-ASCII characters — IAM rejects policy documents that are not printable ASCII"
fi
for c in terraform kubectl gh aws jq git; do need "$c"; done
say "  GitHub session:"; gh auth status 2>&1 | sed 's/^/    /'
confirm "GitHub auth above is you, with repo admin on the fork?" n || die "re-auth with 'gh auth login' first"
AWS_IDENT_JSON="$(aws sts get-caller-identity --output json)" || die "ambient AWS creds unusable — export the admin credentials first"
say "    account: $(jq -r .Account <<<"$AWS_IDENT_JSON")"
say "    arn:     $(jq -r .Arn <<<"$AWS_IDENT_JSON")"

prompt AWS_REGION       "AWS region" "us-east-1"
prompt EKS_CLUSTER_NAME "EKS cluster name (the tenants' cluster)" ""
[ -n "$EKS_CLUSTER_NAME" ] || die "cluster name required"
STATE_BUCKET="namazu-tenant-tfstate-production-308044622771-us-east-1"
aws eks describe-cluster --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME" \
  --query 'cluster.{name:name,version:version,status:status}' --output table \
  || die "cannot describe cluster '$EKS_CLUSTER_NAME' with these creds"
ok "cluster reachable via AWS API"

hdr "Cluster-plane access (rbac.yaml is applied by THIS identity)"
confirm "Run 'aws eks update-kubeconfig' against $EKS_CLUSTER_NAME?" y \
  && aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
for want in "create clusterroles" "create validatingadmissionpolicies"; do
  CAN="$(kubectl auth can-i $want 2>/dev/null || echo no)"
  [ "$CAN" = "yes" ] || die "ambient identity CANNOT '$want' on this cluster — the operator needs an access entry"
  ok "cluster-plane: can $want"
done

hdr "Tenant facts (each addon binds the generic outputs its manifest names)"
for t in "${TENANTS[@]}"; do
  KEY="s3://$STATE_BUCKET/$t/terraform.tfstate"
  if VAL="$(aws s3 cp "$KEY" - 2>/dev/null | jq -r '.values.outputs | keys | join(",")')"; then
    [ -n "$VAL" ] && ok "$t → outputs: $VAL" || skip "$t → statefile unreadable/missing — re-apply that tenant's baseline BEFORE the first real apply"
  else
    skip "$t → statefile unreadable/missing — re-apply that tenant's baseline first"
  fi
done
say "  (check the outputs your addons' manifest.yaml bindings actually name —
   generic platform facts only; the baseline carries zero addon knowledge)"

hdr "Terraform init + plan (bootstrap/)"
ROOT_GIT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"; cd "$ROOT_GIT"
# The bootstrap's OWN state bucket (distinct from STATE_BUCKET, which is
# where the TENANT states + the addon applies live). If a previous manual
# attempt configured a different backend, point this at THE SAME bucket so
# terraform picks up that partial state and reconciles instead of
# re-creating resources (which would 409 EntityAlreadyExists).
prompt BACKEND_BUCKET "Bootstrap state bucket" "$STATE_BUCKET"
prompt BACKEND_KEY   "Bootstrap state key"   "bootstrap/${REPO}.tfstate"
TMPDIR_GL="$(mktemp -d)"; trap 'rm -rf "$TMPDIR_GL"' EXIT
printf 'region  = "%s"\nbucket  = "%s"\nkey     = "%s"\nencrypt = true\n' \
  "$AWS_REGION" "$BACKEND_BUCKET" "$BACKEND_KEY" > "$TMPDIR_GL/backend.hcl"
sed 's/^/    /' "$TMPDIR_GL/backend.hcl"
( cd bootstrap && terraform init -input=false -reconfigure \
    -backend-config="$TMPDIR_GL/backend.hcl" ) || die "terraform init failed"
PLAN_ARGS=( -var="github_organization=$ORG"  -var="repository=$REPO"
            -var="environment=prod"          -var="aws_region=$AWS_REGION"
            -var="eks_cluster_name=$EKS_CLUSTER_NAME" -var="state_bucket=$STATE_BUCKET" )
( cd bootstrap && terraform plan -input=false -no-color "${PLAN_ARGS[@]}" ) \
  | tee "$TMPDIR_GL/plan.txt" || die "terraform plan failed"
say "  $(grep -E 'Plan: [0-9]+ to (add|change|destroy)' "$TMPDIR_GL/plan.txt" | tail -1 || echo 'no resource changes')"
confirm "The plan above is the full and only effect of this apply. Proceed?" n || die "aborted before apply"

hdr "Apply (operator-only: IAM role + policies + access entry)"
read -r -p "  Type 'APPLY' to run terraform apply: " CONFIRM
[ "$CONFIRM" = "APPLY" ] || die "aborted before apply"
( cd bootstrap && terraform apply -input=false -auto-approve -no-color "${PLAN_ARGS[@]}" ) \
  || die "terraform apply failed"
ok "bootstrap applied (state: s3://$STATE_BUCKET/$BACKEND_KEY)"

OUT_JSON="$( (cd bootstrap && terraform output -json) )"
EXECUTOR_ARN="$(jq -r '.executor_role_arn.value' <<<"$OUT_JSON")"
K8S_GROUP="$(jq -r '.kubernetes_group.value' <<<"$OUT_JSON")"
say "    executor role: $EXECUTOR_ARN"
say "    access entry:  $EKS_CLUSTER_NAME → group $K8S_GROUP"

hdr "Kubernetes RBAC (rbac.tf — Terraform-managed, reads rbac.yaml from disk)"
say "  The bootstrap apply just created/reconciled the ClusterRole + Binding"
say "  (kubectl_manifest resources reading bootstrap/rbac.yaml — they live in"
say "   state and are deleted by scripts/teardown.sh's terraform destroy)."
kubectl get clusterrole addons-executor >/dev/null 2>&1 \
  && ok "ClusterRole addons-executor present (Terraform-managed)" \
  || skip "ClusterRole not visible — check the apply output"

hdr "GitHub wiring (repo Variables — each confirmed)"
set_var() { local name="$1" val="$2" cur
  cur="$(gh variable list --json name,value --jq ".[] | select(.name==\"$name\") | .value" 2>/dev/null || true)"
  [ "$cur" = "$val" ] && { skip "variable $name already matches"; return; }
  confirm "Set repo variable $name?" y || { skip "variable $name left as-is"; return; }
  gh variable set "$name" -R "$ORG/$REPO" --body "$val"; ok "variable $name set"; }
set_var ADDONS_EXECUTOR_ROLE_ARN "$EXECUTOR_ARN"
set_var CLUSTER_NAME "$EKS_CLUSTER_NAME"
set_var EKS_ROLE_ARN "$EXECUTOR_ARN"

hdr "Self-assume probe (the runner execs get-token --role-arn AS the executor)"
if aws eks get-token --cluster-name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" \
     --role-arn "$EXECUTOR_ARN" >/dev/null 2>&1; then
  ok "self-assume token mint works"
else
  say "${YLW}  ✗ self-assume FAILED — addon applies will die at their provider; check the bootstrap trust statement${RST}"
fi

hdr "Summary"
say "  ${GRN}done:${RST}";    printf '    ✓ %s\n' "${DONE[@]:-(none)}"
say "  ${YLW}skipped:${RST}"; printf '    - %s\n' "${SKIPPED[@]:-(none)}"
if confirm "Trigger the sync workflow now (gh workflow run sync.yml) and watch it?"; then
  gh workflow run sync.yml -R "$ORG/$REPO" --ref main
  sleep 5
  RUN="$(gh run list -R "$ORG/$REPO" --workflow=sync.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
  gh run watch "$RUN" -R "$ORG/$REPO" --exit-status || true
  gh run view "$RUN" -R "$ORG/$REPO" | sed 's/^/    /'
  ok "sync workflow triggered + watched ($RUN)"
else
  skip "sync workflow not triggered (dispatch or merge later)"
fi
say
say "Re-run me any time — terraform reconciles; wiring overwrites only with confirmation."
