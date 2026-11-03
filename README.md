# namazu-cloud-addon-example

The working template for the per-tenant addon ecosystem: contract files, a
real functioning reference addon, `bootstrap/` executor-role minting, and the
default workflows. F**Forks start compliant because they start working.**

Canonical contract & full design:
[`namazu-cloud-instance/tenant-addons-plan.md`](https://github.com/NamazuStudios/namazu-cloud-instance/blob/main/tenant-addons-plan.md).

## What this repo is

One Terraform root (this IS one addon — the ResourceQuota/NetworkPolicy
bundle) PLUS the org-fork tooling. After forking, you grow into one of three
mature shapes:

| Shape | Keep | Delete | Result |
|---|---|---|---|
| **Pure executor fork** | `bootstrap/` + workflows | the root + `manifest.yaml` | Applies other repos' addons only |
| **Executor + private local root** | everything | nothing · set `manifest.yaml` `visibility: private; owner_org: <your db id>` | Your private addon lives here; applies via repo-less matrix entries |
| **Shared / private addon repo** | the root + `manifest.yaml` | `bootstrap/` + workflows | Your feature becomes a consumable addon |

One repo = one addon, everywhere (bijection: repo suffix `=` addon id `=`
statefile name `=` sweep key).

## Quickstart (first 15 minutes)

1. **Fork or use-as-template** under a human-chosen slug;
   `namazu-cloud-addon-<your-org-slug>` is the convention for org forks.
   Names are permanent (renames are breaking PRs — they move workflow entries
   and `$addon.<id>` refs).
2. **Set `ORGANIZATION_ID`** in `.github/workflows/sync.yml` env to YOUR
   org's database unique id (machine field, never a name).
3. **Run `scripts/go-live.sh`** (interactive; **CI never applies this root** —
   `validate.yml` only fmt/validates). One operator-run apply mints and
   reconciles, from ONE durable S3 state (`bootstrap/<repo>.tfstate`):
   - **IAM plane** — the executor role, its base + feature policies, the
     EKS access entry binding it to the `addons-executor` group;
   - **Cluster plane** (`bootstrap/rbac.tf`) — the `addons-executor`
     ClusterRole + Binding. The kubernetes provider authenticates as
     **whoever runs the apply** (no `--role-arn`), so the apply only ever
     succeeds under an operator who already holds cluster access — the
     executor role is the subject of the RBAC, never the identity that
     reconciles it;
   - **Registry** (`bootstrap/ecr.tf`, if `ecr_repositories` is non-empty) —
     tenant ECR repositories with IMMUTABLE tags + lifecycle, for in-region
     pulls;
   - every minted resource is tagged `Repo`/`Component`, and the script
     reads back everything it created before touching GitHub.
   Then it sets the repo **Variables** (`ADDONS_EXECUTOR_ROLE_ARN`,
   `CLUSTER_NAME`, `EKS_ROLE_ARN`) and optionally the `ELEMENTS_GIT_TOKEN`
   secret. Re-runnable any time — terraform reconciles, wiring overwrites
   only with confirmation.
4. **GitHub wiring (or let go-live.sh do it):** repo *Variables* (not
   secrets) — `ADDONS_EXECUTOR_ROLE_ARN` = bootstrap's `executor_role_arn`
   output, plus `CLUSTER_NAME` / `EKS_ROLE_ARN` (the role the exec plugin
   assumes). Until these exist, `apply`/`sweep`/any cluster-infra job skip
   instead of failing, so a fork stays green while you are still setting up.
5. **Pin the runner: both workflows ship pinned to a full SHA of
   `NamazuStudios/namazu-cloud-addon-runner`. Bump the two `uses:` lines
   together when you want a newer runner — on main the validate workflow fails
   unless each is a full 40-hex SHA or a protected `v<semver>` tag.
6. **Edit the install matrix** in `.github/workflows/sync.yml` — repo-less
   entries apply this fork's local root; external entries pin
   `{addon, ref}`.
7. Push to main → the sync workflow applies your addons to the named
   tenants (deploys happen on main only; PRs validate and never apply).

## What bootstrap creates (the accounting)

Everything the operator-run bootstrap mints is reconciled from ONE state:
`s3://<backend bucket>/bootstrap/<repo>.tfstate` (fleet backend convention:
`region`/`bucket`/`key`/`encrypt=true`, passed at `init` via
`-backend-config`). CI runs `terraform validate` only — apply is manual,
always. All resources carry `Repo=<org>/<repo>` +
`Component=addons-executor-bootstrap` tags:

| Resource | Where | Name |
|---|---|---|
| Executor IAM role | `bootstrap/main.tf` | `<repo>-executor` |
| Base policy (tenant-tree read, addon-key writes, EKS describe) | `bootstrap/main.tf` | `<repo>-executor-base` |
| Feature policy (from `iam.policy.json`) | `bootstrap/main.tf` | inline `feature` on the role |
| OIDC provider (only if none exists) | `bootstrap/main.tf` | token.actions.githubusercontent.com |
| EKS access entry → `addons-executor` group | `bootstrap/main.tf` | principal = the role |
| `addons-executor` ClusterRole + Binding | `bootstrap/rbac.tf` | extend the rules for your addons |
| Tenant ECR repositories (if `ecr_repositories` set) | `bootstrap/ecr.tf` | IMMUTABLE + lifecycle |

## The contract files (reserved prefixes — not yours to change)

- `00-backend.tf` — backend "s3" (bucket/region/key injected by the runner)
- `10-locals.tf` — audit tags / provider default tags / common labels
- `20-variables.tf` — the tenant contract (never redeclare these!)
- `30-providers.tf` — providers + exec-plugin wiring + helm ECR registry
- `manifest.yaml` — your input declaration: `description`, `visibility`,
  `owner_org`, and `input` bindings
  (`$instance.…` / `$addon.<id>.…` / literals / `!` sensitive overrides)

Your files: `feature.tf`, `variables.tf` (addon-owned inputs), `bin/`.

## Wiring examples (manifest.yaml `input`)

```yaml
input:
  max_pods: 40                                # literal
  restricted_cidr: $instance.cdn.cidr_range   # tenant-relative, per invocation
  waf_acl_id: $addon.waf.acl_id               # cross-addon, resolves from that
                                              #   addon's statefile for THIS
                                              #   tenant (loud error if absent)
  mongo_ca: !instance.mongo_end_user_ca_pem   # acknowledged sensitive — env
                                              #   channel only, never on disk
```

## Author rules (inline in feature.tf too)

1. Never re-declare a contract variable (they live in `20-variables.tf`).
2. Never couple to another addon except through outputs/refs.

## Local validation (before pushing)

```bash
terraform fmt -check -recursive .                       # formatting is gated in CI
terraform init -backend=false && terraform validate     # parses root + generates .terraform.lock.hcl (commit it)
(cd bootstrap && terraform init -backend=false && terraform validate)

python3 scripts/addon_tools.py lint-manifest manifest.yaml
python3 scripts/addon_tools.py lint-workflow \
  --workflow .github/workflows/sync.yml --runner-pin pin-required

python3 scripts/addon_tools.py build-index \
  --workflow .github/workflows/sync.yml --repo "$(git config --get remote.origin.url | sed 's#.*github.com[:/]##; s#\.git$##')" \
  --out /tmp/addons.index.json        # materialize + eyeball the sweep's view
```

`IAM policy json (iam.policy.json)` is *not* validated here — bootstrap treats
it as opaque JSON attached verbatim; check it manually or inline in your PR.

## iam.policy.json

Copy `iam.policy.json.example` → `iam.policy.json` and fill in the feature
grants your addon needs (they are diffed in every PR). A leftover
Deny-all example grant is harmless.

## Verified checklist pointers

The implementation checklist lives in the plan doc's §11.6 — enable /
disable / tenant-destroy (destroy-from-state!), cross-addon chaining, tag
upgrades, divergent per-tenant versions, sensitivity channel.
