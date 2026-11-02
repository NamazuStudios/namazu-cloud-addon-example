# Addon-owned inputs — fed from this repo's manifest.yaml `input` bindings.
# Contract variables (instance_id, organization_id, ...) are NOT declared here
# and never will be: see 20-variables.tf and author rule 1 in feature.tf.

variable "max_pods" {
  description = "Per-tenant pod ceiling enforced by the addon-quota ResourceQuota."
  type        = number
  default     = 40
}

variable "enable_network_policy" {
  description = "Also install an addon-default-deny NetworkPolicy in the tenant namespace."
  type        = bool
  default     = false
}

variable "extra_manifests" {
  description = "Optional extra YAML manifests, keyed by slug; slugs are the Terraform addresses."
  type        = map(string)
  default     = {}
}
