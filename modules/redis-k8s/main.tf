terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.38.0, < 3.0.0"
    }
  }
}

# The Kubernetes target is bound by the executor through the provider
# environment; the module never configures a host, token or kubeconfig.
provider "kubernetes" {}

variable "namespace" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a DNS label."
  }
}

# Pinned image. The default is the verified multi-architecture index digest of
# redis 7.4.7 (Alpine). A Definition may pin another reference, but only a
# digest-pinned one (tags are mutable).
variable "image" {
  type    = string
  default = "redis:7.4.7-alpine@sha256:02f2cc4882f8bf87c79a220ac958f58c700bdec0dfb9b9ea61b62fb0e8f1bfcf"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9._-]{1,128})?@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be a digest-pinned reference (name[:tag]@sha256:<64 hex>)."
  }
}

variable "username" {
  type    = string
  default = "app"
  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{0,31}$", var.username)) && var.username != "default"
    error_message = "username must be a lowercase identifier other than default."
  }
}

variable "storage" {
  type    = string
  default = "1Gi"
  validation {
    condition     = can(regex("^[1-9][0-9]{0,3}(Mi|Gi)$", var.storage))
    error_message = "storage must be a whole number of Mi or Gi."
  }
}

# Empty selects the cluster default storage class. The module never creates or
# changes a storage class.
variable "storage_class" {
  type    = string
  default = ""
}

# Optional nonsecret metadata consumed by the Redis objects. Secret-looking
# keys are refused so a credential output cannot become public metadata.
variable "labels" {
  type    = map(string)
  default = {}
  validation {
    condition = alltrue([
      for k, v in var.labels :
      can(regex("^([a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$", k)) &&
      can(regex("^([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?$", v)) &&
      !can(regex("(?i)(password|secret|token|credential)", k)) &&
      !startswith(k, "app.kubernetes.io/") && !startswith(k, "orchestrator")
    ])
    error_message = "labels must be valid nonsecret Kubernetes labels outside the platform-owned keys."
  }
}

variable "annotations" {
  type    = map(string)
  default = {}
  validation {
    condition = alltrue([
      for k, v in var.annotations :
      can(regex("^([a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$", k)) &&
      !can(regex("(?i)(password|secret|token|credential)", k)) &&
      !startswith(k, "app.kubernetes.io/") && !startswith(k, "orchestrator")
    ])
    error_message = "annotations must have valid nonsecret keys outside the platform-owned keys."
  }
}

# Executor-owned: the stable password (one secret-store reference per
# instance, reused across retries) and the stable platform tags.
variable "password" {
  type      = string
  sensitive = true
}

variable "tags" {
  type = map(string)
  validation {
    condition     = can(regex("^[0-9a-f]{8,64}$", lookup(var.tags, "orchestrator-instance", "")))
    error_message = "tags must carry the stable orchestrator-instance key."
  }
}

locals {
  key         = var.tags["orchestrator-instance"]
  name        = "redis-${local.key}"
  host        = "${local.name}.${var.namespace}.svc"
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
  selector = {
    "app.kubernetes.io/name"     = "redis"
    "app.kubernetes.io/instance" = local.name
  }
  labels = merge(var.labels, local.platform_labels, local.selector, {
    "app.kubernetes.io/managed-by" = "orchestrator"
  })
  annotations = merge(var.annotations, local.platform_annotations)
}

# Credentials for the pod only. Consumers receive the password through the
# orchestrator's secret-store output, never from this object's metadata.
resource "kubernetes_secret_v1" "auth" {
  metadata {
    name        = "${local.name}-auth"
    namespace   = var.namespace
    labels      = local.labels
    annotations = local.annotations
  }
  data = {
    username = var.username
    password = var.password
  }
}

# The data volume is its own state-owned object (not a volumeClaimTemplate), so
# destroy removes the StatefulSet first and the claim second, and the claim is
# never an unaccounted object of the namespace.
resource "kubernetes_persistent_volume_claim_v1" "data" {
  metadata {
    name        = "${local.name}-data"
    namespace   = var.namespace
    labels      = local.labels
    annotations = local.annotations
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class == "" ? null : var.storage_class
    resources {
      requests = {
        storage = var.storage
      }
    }
  }
  # Readiness is checked by the executor after the state is acknowledged; the
  # provider must not block the create on a consumer-bound volume.
  wait_until_bound = false
}

resource "kubernetes_service_v1" "this" {
  metadata {
    name        = local.name
    namespace   = var.namespace
    labels      = local.labels
    annotations = local.annotations
  }
  spec {
    type     = "ClusterIP"
    selector = local.selector
    port {
      name        = "redis"
      port        = 6379
      target_port = "redis"
      protocol    = "TCP"
    }
  }
}

# One Redis with ACL authentication. The default user is disabled and the
# application user gets a password from the Secret, so no unauthenticated
# command is accepted (protected mode only matters for a passwordless default
# user and would refuse the in-cluster clients). The ACL file is written into a
# memory-backed volume from the environment so the password is not in the
# process arguments.
resource "kubernetes_stateful_set_v1" "this" {
  metadata {
    name        = local.name
    namespace   = var.namespace
    labels      = local.labels
    annotations = local.annotations
  }
  # The provider must not wait for pod readiness: a pod that never becomes
  # ready would otherwise fail the create before the state is acknowledged.
  # The executor runs the bounded readiness check afterwards.
  wait_for_rollout = false

  spec {
    service_name = kubernetes_service_v1.this.metadata[0].name
    replicas     = "1"
    selector {
      match_labels = local.selector
    }
    update_strategy {
      type = "RollingUpdate"
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        automount_service_account_token  = false
        termination_grace_period_seconds = 30
        security_context {
          run_as_user     = "999"
          run_as_group    = "1000"
          run_as_non_root = true
          fs_group        = "1000"
        }
        container {
          name              = "redis"
          image             = var.image
          image_pull_policy = "IfNotPresent"
          command = [
            "sh", "-c",
            "umask 077 && printf 'user default off\\nuser %s on >%s ~* &* +@all\\n' \"$REDIS_USERNAME\" \"$REDIS_PASSWORD\" > /acl/users.acl && exec redis-server --aclfile /acl/users.acl --appendonly yes --dir /data --bind 0.0.0.0 --protected-mode no"
          ]
          port {
            name           = "redis"
            container_port = 6379
            protocol       = "TCP"
          }
          env {
            name = "REDIS_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.auth.metadata[0].name
                key  = "username"
              }
            }
          }
          env {
            name = "REDIS_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.auth.metadata[0].name
                key  = "password"
              }
            }
          }
          readiness_probe {
            exec {
              command = ["sh", "-c", "REDISCLI_AUTH=\"$REDIS_PASSWORD\" redis-cli --user \"$REDIS_USERNAME\" ping | grep -q PONG"]
            }
            initial_delay_seconds = 3
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 6
          }
          liveness_probe {
            tcp_socket {
              port = "redis"
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 6
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "acl"
            mount_path = "/acl"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.data.metadata[0].name
          }
        }
        volume {
          name = "acl"
          empty_dir {
            medium     = "Memory"
            size_limit = "1Mi"
          }
        }
      }
    }
  }
}

output "host" { value = local.host }
output "port" { value = 6379 }
output "username" { value = var.username }
output "tls" { value = false }

output "password" {
  value     = var.password
  sensitive = true
}
