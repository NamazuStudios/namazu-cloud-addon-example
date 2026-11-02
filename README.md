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
3. **Bootstrap the executor role** (one-time; admin creds):
   ```bash
   terraform -chdir=bootstrap init
   terraform -chdir=bootstrap apply \
     -var=repository=namazu-cloud-addon-<your-org-slug> \
     -var=aws_region=<region> \
     -var=eks_cluster_name=<cluster> \
     -var=state_bucket=<backend bucket>
   ```
4. **Apply `bootstrap/rbac.yaml` once per cluster:**
   `kubectl apply -f bootstrap/rbac.yaml`
5. **Add the role to GitHub:** repo *Variables* (not secrets) →
   `ADDONS_EXECUTOR_ROLE_ARN` = bootstrap's `executor_role_arn` output.
6. **Pin the runner:** replace `<PICK-A-RUNNER-SHA>` in both workflows with a
   full SHA of `NamazuStudios/namazu-cloud-addon-runner`. On main, the
   validate workflow fails while the placeholder survives.
7. **Edit the install matrix** in `.github/workflows/sync.yml` — repo-less
   entries apply this fork's local root; external entries pin
   `{addon, ref}`.
8. Push to main → the sync workflow applies your addons to the named tenants.

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

## iam.policy.json

Copy `iam.policy.json.example` → `iam.policy.json` and fill in the feature
grants your addon needs (they are diffed in every PR). A leftover
Deny-all example grant is harmless.

## Verified checklist pointers

The implementation checklist lives in the plan doc's §11.6 — enable /
disable / tenant-destroy (destroy-from-state!), cross-addon chaining, tag
upgrades, divergent per-tenant versions, sensitivity channel.
