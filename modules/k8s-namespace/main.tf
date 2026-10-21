terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.38.0, < 3.0.0"
    }
  }
}

# The Kubernetes target (a scoped Connection kubeconfig or a completed EKS
# target) is bound by the executor through the provider environment. The
# module never configures a host, token, kubeconfig or context.
provider "kubernetes" {}

variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.name)) && !startswith(var.name, "kube-") && !contains(["default", "kube-system", "kube-public", "kube-node-lease"], var.name)
    error_message = "name must be a DNS label and must not be a reserved Kubernetes namespace."
  }
}

# Executor-owned: stable platform tags of the instance (managed-by, instance,
# run provenance, expiry).
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  label_key   = "^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$"
  label_value = "^([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?$"
  platform_labels = {
    for k, v in var.tags : k => v
    if can(regex(local.label_key, k)) && can(regex(local.label_value, v))
  }
  platform_annotations = {
    for k, v in var.tags : k => v
    if can(regex(local.label_key, k))
  }
}

# The namespace is a state-owned object of exactly one instance. Its children
# (Redis, PostgreSQL) have their own instances and are destroyed first by the
# reverse resource graph; the executor refuses to delete a namespace that
# still holds objects this state does not own.
resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.name
    labels = merge(local.platform_labels, {
      "app.kubernetes.io/managed-by" = "orchestrator"
    })
    annotations = local.platform_annotations
  }
  wait_for_default_service_account = false
}

output "name" { value = kubernetes_namespace_v1.this.metadata[0].name }
