# bootstrap/ — mint this fork's executor authority (operator-run only)

What this creates, in ONE apply from ONE durable state
(`s3://<backend bucket>/bootstrap/<repo>.tfstate`):

1. Optional: the GitHub OIDC IAM provider (`token.actions.githubusercontent.com`,
   created only if you didn't pass `github_oidc_provider_arn`).
2. `aws_iam_role.<repo>-executor` with trust pinned to
   `repo:<owner>/<repo>:environment:<environment>` and
   `repo:<owner>/<repo>:ref:refs/heads/main` — the fork's scheduled/PR runs,
   nothing else (plus a self-assume statement: the addon runner execs
   `get-token --role-arn` AS this role from within a session that IS it).
3. Two attached policies:
   - `base` — every executor role: read the tenant tree, list with
     `s3:prefix=tenants/`, put/delete ONLY `tenants/*/addon_*.tfstate`
     (+ `.tflock`), `eks:DescribeCluster`. **Never** a baseline
     `terraform.tfstate` write.
   - `feature` — your `iam.policy.json` (skip-if-absent on a fresh fork).
4. `aws_eks_access_entry` binding the role into the `addons-executor`
   Kubernetes group — whose verbs live in `rbac.tf`, reconciled by THIS same
   apply. The kubernetes provider authenticates as whoever runs the apply
   (no `--role-arn`), so only an operator with their own cluster access can
   run it: CI validates this root but can never apply it, and the executor
   role is the subject of the RBAC, never the identity that mints it.
5. Optional: tenant ECR repositories (`ecr.tf`, when `ecr_repositories` is
   non-empty) — IMMUTABLE tags, scan-on-push, lifecycle, optional pull policy.

Everything carries `Repo=<org>/<repo>` / `Component=addons-executor-bootstrap`
tags, so IAM listings can answer "what exists because of this repo" without
the statefile.

## Run it — use the script

`scripts/go-live.sh` walks the whole thing interactively (preflight probes,
backend config echo, plan + typed `APPLY` confirmation, explicit read-out of
everything minted, GitHub wiring). By hand it is:

```bash
cd bootstrap
terraform init -backend-config=bucket=<backend bucket> \
               -backend-config=key=bootstrap/<repo>.tfstate \
               -backend-config=region=us-east-1
terraform apply \
  -var=repository=namazu-cloud-addon-<your-org-slug> \
  -var=aws_region=us-east-1 \
  -var=eks_cluster_name=<cluster> \
  -var=state_bucket=<backend bucket> \
  # optional:
  #  -var=environment=prod \
  #  -var=github_oidc_provider_arn=arn:aws:iam::<acct>:oidc-provider/token.actions.githubusercontent.com \
  #  -var=feature_policy_json="$(cat ../iam.policy.json)" \
  #  -var='ecr_repositories=["<tenant-image>"]'
```

Then:

- take the `executor_role_arn` output → repo *Variables*
  (not secrets) → `ADDONS_EXECUTOR_ROLE_ARN` (the workflows assume it via
  `aws-actions/configure-aws-credentials`);
- done. Re-run the apply ONLY when IAM/trust/RBAC changes (terraform
  reconciles; the RBAC rules are reviewed in PRs); it is deliberately not
  part of CI.

## IAM actions the bootstrapping admin needs

`iam:CreateRole/TagRole/PutRolePolicy/CreateInstanceProfile`-adjacent for the
role, `iam:CreateOpenIDConnectProvider` (only when creating the provider),
`s3:GetBucketLocation` + the bucket's write path (the backend), and
`eks:CreateAccessEntry/Associate*` for the EKS side — plus the operator's OWN
access entry on the cluster (rbac.tf's provider runs as them).
