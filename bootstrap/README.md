# bootstrap/ — mint this fork's executor role (one-time, admin creds)

What this creates, in order:

1. Optional: the GitHub OIDC IAM provider (`token.actions.githubusercontent.com`,
   created only if you didn't pass `github_oidc_provider_arn`).
2. `aws_iam_role.<repo>-executor` with trust pinned to
   `repo:<owner>/<repo>:environment:<environment>` and
   `repo:<owner>/<repo>:ref:refs/heads/main` — the fork's scheduled/PR runs,
   nothing else.
3. Two attached policies:
   - `base` — every executor role: read the tenant tree, list with
     `s3:prefix=tenants/`, put/delete ONLY `tenants/*/addon_*.tfstate`
     (+ `.tflock`), `eks:DescribeCluster`. **Never** a baseline
     `terraform.tfstate` write.
   - `feature` — your `iam.policy.json` (skip-if-absent on a fresh fork).
4. `aws_eks_access_entry` binding the role into the `addons-executor`
   Kubernetes group (whose verbs live in `rbac.yaml`, applied by you).

## Run it

```bash
cd bootstrap
terraform init
terraform apply \
  -var=repository=namazu-cloud-addon-<your-org-slug> \
  -var=aws_region=us-east-1 \
  -var=eks_cluster_name=<clsuter> \
  -var=state_bucket=<backend bucket> \
  # optional:
  #  -var=environment=prod \
  #  -var=github_oidc_provider_arn=arn:aws:iam::<acct>:oidc-provider/token.actions.githubusercontent.com \
  #  -var=feature_policy_json="$(cat ../iam.policy.json)"
```

Then:

- take the `executor_role_arn` output → repo *Variables*
  (not secrets) → `ADDONS_EXECUTOR_ROLE_ARN` (the workflows assume it via
  `aws-actions/configure-aws-credentials`);
- `kubectl apply -f rbac.yaml` once per cluster (give the group their verbs);
- done. Re-run bootstrap ONLY when IAM/trust changes; it is deliberately not
  part of CI.

## IAM actions the bootstrapping admin needs

`iam:CreateRole/TagRole/PutRolePolicy/CreateInstanceProfile`-adjacent for the
role, `iam:CreateOpenIDConnectProvider` (only when creating the provider),
`s3:GetBucketLocation` (to validate the bucket ref), and
`eks:CreateAccessEntry/Associate*` for the EKS side.

## Least-privilege notes

- The role's *policy* is additive over the plan-documented base grant; a
  leftover Deny-all example `feature` block is harmless by construction.
- The trust `sub` is pinned to this repo + environment + `main` — the
  scheduled sweep runs on `main`'s OIDC claim, PR checks never get the role
  unless the environment allows.
- Dormant fork ⇒ the executor never runs ⇒ the role stays dormant; role
  lifecycle follows repo lifecycle (delete the role when decommissioning).
