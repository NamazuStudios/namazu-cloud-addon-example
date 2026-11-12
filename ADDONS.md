# Addons on Namazu Cloud — how tenants get them

> System overview: [namazu-cloud-addon](https://github.com/NamazuStudios/namazu-cloud-addon)

There are two ways an addon lands in your namespaces: **activate one of the
official addons**, or **bring your own**. Both go through Namazu Studios —
we are the operators of the shared cluster, and every addon runs under an
org-fork executor identity we provision with least privilege.

## Official addons (activate for a fixed fee)

These are written, audited, and maintained by Namazu Studios. They can be
activated for a **fixed fee** — open a support request and we enable them
for your namespaces:

| Addon | What it gives you |
|---|---|
| [`namazu-cloud-addon-gpu`](https://github.com/NamazuStudios/namazu-cloud-addon-gpu) | Opt-in GPU node capacity: Karpenter GPU tiers (g4dn/g5/g6/g7), per-tenant quota, single-GPU or 4-GPU `-xl` shapes |
| [`namazu-cloud-addon-fast-storage-class`](https://github.com/NamazuStudios/namazu-cloud-addon-fast-storage-class) | A provisioned fast StorageClass per namespace (up to 16,000 IOPS / 1,000 MiB/s) — built for snapshot lazy-restore cold starts |
| [`namazu-cloud-addon-organization-ecr-repository`](https://github.com/NamazuStudios/namazu-cloud-addon-organization-ecr-repository) | An ECR repository in our registry, org-namespaced, per-namespace pull control, CI push roles |
| [`namazu-cloud-addon-agent-apn`](https://github.com/NamazuStudios/namazu-cloud-addon-agent-apn) | AWS wiring for the co-selling agent (Partner Central): outbound assume, optional co-sell role, ECR pull |

## Bringing your own addon

This repository is the template. It is **MIT-licensed** on purpose: copy
it, and what you build is yours.

1. **Make a private clone of this project** and write the Terraform you
   wish to install, plus its `manifest.yaml` (the input declaration the
   runner reads — this repo's `manifest.yaml` and `feature.tf` show the
   shape, and the author rules in `feature.tf` are the contract).
2. **Open a paid support ticket with Namazu Studios.** We review the code.
   **Each support ticket includes five (5) security audit and reviews** of
   the addon.
3. **Once we approve, we install it to your namespaces at your request.**

### Or: we author it for you

Writing the Terraform yourself is optional. **Namazu Studios can author a
custom addon for you, for a fee scoped to the work required** — tell us
what you need installed, and we will write it, review it internally, and
install it through the same process. The maintenance terms below are the
same either way; the difference is who writes the first draft and the
price, which scales with the work rather than a fixed ticket.

### Once your addon is live

- You maintain it by **opening pull requests**, which we review.
- We offer **unlimited PR reviews, within reason**, as long as the
  **permissions boundary doesn't change** — the IAM/RBAC grants your addon
  was approved with are frozen; code changes inside that boundary are
  reviewed in the normal PR flow.
- **Changing the permissions boundary is a new paid support request
  cycle** (a fresh review and audit, because a new boundary is new risk).

### Terms

- **We reserve the right to reject anything.** A rejection is a reviewed
  decision, not a formality — but it is ours to make.
- **The support request is nonrefundable.**
- **We take all reasonable efforts to approve everything** — our reviews
  exist to make your addon land safely, not to fail it.
- **AGPL waiver for delivered work.** Namazu Studios, as the copyright holder, waives all AGPL obligations for software installed through a purchase or other business arrangement between Namazu Studios and the client. The AGPL terms govern the code as published; what we deliver to you under contract is delivered under that agreement, not the license's reciprocity terms.
- **We operate a shared responsibility model.** Namazu Studios is
  responsible for **auditing security and protecting the health of the
  cluster** (the control plane, the executor identities, the platform).
  **The tenant is responsible for what they govern and control** — their
  addon's Terraform, its inputs, its workloads, and the resources those
  govern.

## Why the executor is ours, and the least-privilege boundary is too

The runner (`namazu-cloud-addon-runner`) enforces the addon contract: your
addon's Terraform runs under a least-privilege executor identity we mint
per org, scoped so it can only ever touch its own addon state — never your
baseline, never another org's anything. That is why the permission
boundary is the review gate: within it, you iterate freely; across it, we
start a new review.
