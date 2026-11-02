# ResourceQuota + optional NetworkPolicy bundle — the reference addon.
#
# The two author rules (they are the contract, stated inline so forks inherit):
#  1. NEVER re-declare a variable from 20-variables.tf — those are the tenant
#     contract, not yours. Addon-semantics inputs live in variables.tf and are
#     fed from manifest.yaml's `input` bindings.
#  2. NEVER couple to another addon except through its outputs (via
#     `$addon.<id>.<output>` bindings in manifest.yaml). No cross-repo
#     scheduling exists — wiring resolves against that addon's statefile.

resource "kubectl_manifest" "resource_quota" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ResourceQuota"
    metadata = {
      name      = "addon-quota"
      namespace = local.addon_namespace # namespaced by the skeleton
      labels    = local.common_labels   # tagged/audited by the skeleton
    }
    spec = {
      hard = {
        pods = tostring(var.max_pods)
      }
    }
  })
}

resource "kubectl_manifest" "network_policy" {
  count = var.enable_network_policy ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "addon-default-deny"
      namespace = local.addon_namespace
      labels    = local.common_labels
    }
    spec = {
      podSelector : {}
      policyTypes : ["Ingress", "Egress"]
    }
  })
}

resource "kubectl_manifest" "extra" {
  for_each           = var.extra_manifests
  yaml_body          = each.value
  override_namespace = local.addon_namespace
}
