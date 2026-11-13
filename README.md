# namazu-cloud-addon-example


> **This is the template for tenants who want their own [Namazu Cloud](https://cloud.namazustudios.com) addon.**
> Part of the [Namazu Cloud Addon system](https://github.com/NamazuStudios/namazu-cloud-addon). Clone it, write your Terraform, and open a paid support ticket with Namazu
> Studios — we review, audit, and install it into your namespaces. The full
> process, terms, and shared-responsibility model: **[ADDONS.md](ADDONS.md)**.
>
> Our **official addons** — [gpu](https://github.com/NamazuStudios/namazu-cloud-addon-gpu),
> [fast-storage-class](https://github.com/NamazuStudios/namazu-cloud-addon-fast-storage-class),
> [organization-ecr-repository](https://github.com/NamazuStudios/namazu-cloud-addon-organization-ecr-repository),
> [agent-apn](https://github.com/NamazuStudios/namazu-cloud-addon-agent-apn) —
> can be activated for a **fixed fee** without writing any Terraform.
>
> **License: MIT** — this template is intentionally permissive: what you
> build from it is yours. (The official addons and the runner are
> AGPL-3.0, and are [Namazu Cloud](https://cloud.namazustudios.com)'s.)


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

## Teardown (decommissioning a fork)

Order matters — the platform enforces the middle step:

1. **Empty the install matrix** — delete the entries from the fork's
   `.github/workflows/sync.yml`; the fork's sweep destroys each addon
   install from state and tidies its key. Verify no
   `tenants/*/<tenant>/addon_*.tfstate` keys remain.
2. **Tenants can now be destroyed** — the deploy container refuses a tenant
   destroy while any addon state key exists (destroy gate,
   `namazu-cloud-instance` `docker/entrypoint.sh`), so this is what
   unblocks tenant deletion.
3. **Destroy the bootstrap** — `terraform -chdir=bootstrap destroy`
   (backend-config as at init): takes down the executor role + policies,
   the access entry, the `addons-executor` ClusterRole/Binding, and any ECR
   repositories. This state lives **outside** `tenants/` and outside the
   platform's sweep/gate by design — bootstrap authority is minted and
   destroyed only by an operator.
4. Remove the repo Variables (`ADDONS_EXECUTOR_ROLE_ARN`, `CLUSTER_NAME`,
   `EKS_ROLE_ARN`) and the `ELEMENTS_GIT_TOKEN` secret.

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

---

## Example use cases orgs build with addons

The addon system is generic Terraform-in-a-fork, but the workloads it
lands are concrete. A few real shapes:

### Per-tenant AI image generation (the full stack)

A SaaS where every customer generates images or music with their own
boundaries:

- **gpu** — a dedicated Karpenter GPU pool per tenant (single-GPU serving
  shapes, optional self-reclaiming 4-GPU pools for batch renders), quota
  capped per tenant so one customer's burst never starves another.
- **fast-storage-class** — a provisioned gp3 class per namespace so the
  worker's multi-GB diffusion checkpoint restores from snapshot in
  minutes, not half an hour; LoRA adapters swap per request.
- **organization-ecr-repository** — the tenant's inference image (CUDA
  base + model runtime, 5-8 GB) pinned by digest in-region, so every
  freshly-provisioned GPU node pulls the exact tested build in seconds.

One matrix entry per tenant turns a new customer on; the sweep turns
them off.

### Fine-tuned model serving with LoRA adapters

Train LoRA adapters offline, ship them as volumes restored from
snapshot through the fast storage class, serve on a GPU pool capped at
the tenant's plan, and pin the serving image by digest so the adapter +
runtime pairing is reproducible. Quota changes are a contract edit, not
an infrastructure project.

### Batch generation pipelines

Video or music generation runs nightly per tenant on spot capacity
(`capacity_types=["spot"]` in the entry), bursting into the -xl pools
for the heavy multi-GPU stages, with the self-reclaim expiry returning
the expensive machines automatically when the batch window closes.

### Plain-tenant platform add-ons

Not every addon is AI: ResourceQuota + default-deny NetworkPolicy (this
repo's example root), in-account ECR for container images, SES wiring —
anything an org needs that the shared cluster doesn't give by default.

See [ADDONS.md](ADDONS.md) for how these get reviewed and installed, or
the official addons for the fixed-fee versions of the pieces above.
