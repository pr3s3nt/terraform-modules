terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.60.0, < 7.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.38.0, < 3.0.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

provider "kubernetes" {}

variable "region" { type = string }

variable "vpc_id" { type = string }

variable "cluster_name" { type = string }

variable "namespace" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a DNS label."
  }
}

# The shared internal ALB (internal-alb outputs listenerArn, securityGroupId
# and url).
variable "listener_arn" { type = string }
variable "alb_security_group_id" { type = string }
variable "alb_url" { type = string }

# ${context.res.id}: modules.<workload>.externals.<alias> selects the Pods.
variable "res_id" {
  type = string
  validation {
    condition     = can(regex("^modules\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\\.externals\\.", var.res_id))
    error_message = "res_id must be the resource ID of a workload-private resource (declare it in the workload Score without id)."
  }
}

variable "port" {
  type = number
  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a TCP port number."
  }
}

# ALB path pattern, for example /auth/*.
variable "path" {
  type = string
  validation {
    condition     = can(regex("^/[A-Za-z0-9_./*-]{0,127}$", var.path))
    error_message = "path must be an ALB path pattern starting with /."
  }
}

# 0 derives a stable priority from the path; set it only to resolve a clash.
variable "priority" {
  type    = number
  default = 0
  validation {
    condition     = var.priority >= 0 && var.priority <= 50000 && floor(var.priority) == var.priority
    error_message = "priority must be 0 (derived) or a whole number up to 50000."
  }
}

variable "health_path" {
  type    = string
  default = "/"
  validation {
    condition     = startswith(var.health_path, "/")
    error_message = "health_path must start with /."
  }
}

variable "tags" {
  type = map(string)
  validation {
    condition     = can(regex("^[0-9a-f]{8,64}$", lookup(var.tags, "orchestrator-instance", "")))
    error_message = "tags must carry the stable orchestrator-instance key."
  }
}

locals {
  key      = var.tags["orchestrator-instance"]
  name     = "orc-${substr(local.key, 0, 16)}-rt"
  workload = regex("^modules\\.([a-z0-9-]+)\\.externals\\.", var.res_id)[0]
  priority = var.priority > 0 ? var.priority : parseint(substr(sha1(var.path), 0, 4), 16) % 49000 + 1000
  prefix   = trimsuffix(trimsuffix(var.path, "*"), "/")
  labels = merge({
    for k, v in var.tags : k => v
    if can(regex("^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$", k)) && can(regex("^([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?$", v))
  }, { "app.kubernetes.io/managed-by" = "orchestrator" })
}

resource "kubernetes_service_v1" "this" {
  metadata {
    name      = "${local.workload}-internal"
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    type                    = "NodePort"
    external_traffic_policy = "Cluster"
    selector                = { "app.kubernetes.io/name" = local.workload }
    port {
      name        = "http"
      port        = var.port
      target_port = var.port
      protocol    = "TCP"
    }
  }
}

locals {
  node_port = kubernetes_service_v1.this.spec[0].port[0].node_port
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_node_groups" "this" {
  cluster_name = var.cluster_name
}

data "aws_eks_node_group" "this" {
  for_each        = data.aws_eks_node_groups.this.names
  cluster_name    = var.cluster_name
  node_group_name = each.key
}

locals {
  cluster_sg = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  node_asgs = toset(flatten([
    for group in data.aws_eks_node_group.this : [
      for r in group.resources : [for asg in r.autoscaling_groups : asg.name]
    ]
  ]))
}

resource "aws_vpc_security_group_egress_rule" "alb_to_nodes" {
  security_group_id            = var.alb_security_group_id
  referenced_security_group_id = local.cluster_sg
  from_port                    = local.node_port
  to_port                      = local.node_port
  ip_protocol                  = "tcp"
  description                  = "Internal ALB to ${local.workload}"
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  security_group_id            = local.cluster_sg
  referenced_security_group_id = var.alb_security_group_id
  from_port                    = local.node_port
  to_port                      = local.node_port
  ip_protocol                  = "tcp"
  description                  = "Internal ALB to ${local.workload}"
}

resource "aws_lb_target_group" "this" {
  name                 = local.name
  port                 = local.node_port
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = var.health_path
    matcher             = "200-399"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_autoscaling_attachment" "this" {
  for_each               = local.node_asgs
  autoscaling_group_name = each.key
  lb_target_group_arn    = aws_lb_target_group.this.arn
}

resource "aws_lb_listener_rule" "this" {
  listener_arn = var.listener_arn
  priority     = local.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    path_pattern {
      values = [var.path]
    }
  }
}

output "url" { value = "${var.alb_url}${local.prefix}" }
output "target_group_arn" { value = aws_lb_target_group.this.arn }
output "priority" { value = local.priority }
