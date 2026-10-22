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

# AWS: the Definition Driver Account and region. Kubernetes: the completed EKS
# target bound by the executor; the module never configures host or token.
provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

provider "kubernetes" {}

variable "region" { type = string }

variable "vpc_id" { type = string }

# The public subnets of the VPC (VPC output publicSubnetIds).
variable "public_subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "public_subnet_ids must list at least two public subnets."
  }
}

# EKS cluster name (k8s-cluster output name); node groups and the cluster
# security group are looked up from it.
variable "cluster_name" { type = string }

variable "namespace" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a DNS label."
  }
}

# The resource ID of this node (${context.res.id}). A workload-private
# resource is modules.<workload>.externals.<alias>; the workload name selects
# the Pods (app.kubernetes.io/name) the load balancer sends traffic to.
variable "res_id" {
  type = string
  validation {
    condition     = can(regex("^modules\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\\.externals\\.", var.res_id))
    error_message = "res_id must be the resource ID of a workload-private resource (declare it in the workload Score without id)."
  }
}

# Container port of the workload.
variable "port" {
  type = number
  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a TCP port number."
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

# Route 53 public hosted zone and the full host name of the endpoint. Both set:
# an ACM certificate is issued and validated in the zone, HTTPS serves the
# traffic and HTTP redirects to it. Both empty: plain HTTP on the ALB name.
variable "hosted_zone_id" {
  type    = string
  default = ""
}

variable "domain_name" {
  type    = string
  default = ""
  validation {
    condition     = var.domain_name == "" || can(regex("^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.domain_name))
    error_message = "domain_name must be empty or a lowercase host name."
  }
}

# Requests per 5 minutes from one IP before AWS WAF blocks it.
variable "rate_limit" {
  type    = number
  default = 2000
  validation {
    condition     = var.rate_limit >= 100 && var.rate_limit <= 2000000000
    error_message = "rate_limit must be at least 100."
  }
}

variable "access_log_retention_days" {
  type    = number
  default = 90
}

variable "idle_timeout" {
  type    = number
  default = 60
}

# false keeps the access log bucket when it still holds logs; development
# Definitions set true so the platform cleanup can remove it.
variable "allow_destroy" {
  type    = bool
  default = false
}

variable "create_dashboard" {
  type    = bool
  default = true
}

variable "tags" {
  type = map(string)
  validation {
    condition     = can(regex("^[0-9a-f]{8,64}$", lookup(var.tags, "orchestrator-instance", "")))
    error_message = "tags must carry the stable orchestrator-instance key."
  }
}

data "aws_caller_identity" "current" {}

locals {
  key      = var.tags["orchestrator-instance"]
  short    = substr(local.key, 0, 16)
  name     = "orc-${local.short}-pub"
  workload = regex("^modules\\.([a-z0-9-]+)\\.externals\\.", var.res_id)[0]
  tls      = var.hosted_zone_id != "" && var.domain_name != ""
  hostname = local.tls ? var.domain_name : aws_lb.this.dns_name
  labels = merge({
    for k, v in var.tags : k => v
    if can(regex("^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$", k)) && can(regex("^([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?$", v))
  }, { "app.kubernetes.io/managed-by" = "orchestrator" })
}

# NodePort Service in front of the workload Pods. The ALB reaches it on every
# node of the cluster (instance targets), so no in-cluster controller is needed.
resource "kubernetes_service_v1" "this" {
  metadata {
    name      = "${local.workload}-public"
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

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public ALB of ${local.workload}"
  vpc_id      = var.vpc_id
  tags        = { Name = "${local.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  count             = local.tls ? 1 : 0
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "to_nodes" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = local.cluster_sg
  from_port                    = local.node_port
  to_port                      = local.node_port
  ip_protocol                  = "tcp"
}

# The rule belongs to this state; the EKS cluster security group itself is
# owned by the cluster.
resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  security_group_id            = local.cluster_sg
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = local.node_port
  to_port                      = local.node_port
  ip_protocol                  = "tcp"
  description                  = "Public ALB ${local.name} to ${local.workload}"
}

# Access logs. ALB log delivery supports only SSE-S3.
resource "aws_s3_bucket" "logs" {
  bucket        = "orc-${substr(local.key, 0, 32)}-alblogs-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.allow_destroy
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.access_log_retention_days
    }
  }
}

data "aws_elb_service_account" "this" {}

data "aws_iam_policy_document" "logs" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket     = aws_s3_bucket.logs.id
  policy     = data.aws_iam_policy_document.logs.json
  depends_on = [aws_s3_bucket_public_access_block.logs]
}

resource "aws_lb" "this" {
  name                       = local.name
  internal                   = false
  load_balancer_type         = "application"
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  idle_timeout               = var.idle_timeout
  drop_invalid_header_fields = true
  enable_deletion_protection = false

  access_logs {
    bucket  = aws_s3_bucket.logs.id
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.logs]
}

resource "aws_lb_target_group" "this" {
  name                 = "${local.name}-tg"
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

resource "aws_acm_certificate" "this" {
  count             = local.tls ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for o in flatten(aws_acm_certificate.this[*].domain_validation_options) : o.domain_name => o
  }
  zone_id         = var.hosted_zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count                   = local.tls ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

resource "aws_lb_listener" "https" {
  count             = local.tls ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this[0].certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.tls ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.tls ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this.arn
    }
  }
}

resource "aws_route53_record" "alias" {
  count   = local.tls ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

resource "aws_wafv2_web_acl" "this" {
  name  = "${local.name}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit"
    priority = 0
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-rate"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = ["AWSManagedRulesAmazonIpReputationList", "AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet"]
    content {
      name     = rule.value
      priority = rule.key + 1
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          name        = rule.value
          vendor_name = "AWS"
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-${rule.value}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

resource "aws_cloudwatch_dashboard" "this" {
  count          = var.create_dashboard ? 1 : 0
  dashboard_name = "${local.name}-${local.workload}"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Public ALB requests and errors"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.this.arn_suffix],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
            [".", "HTTPCode_Target_4XX_Count", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "${local.workload} latency and healthy targets"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "p95" }],
            [".", "HealthyHostCount", "TargetGroup", aws_lb_target_group.this.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Minimum" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 24, height = 6
        properties = {
          title  = "AWS WAF"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/WAFV2", "AllowedRequests", "WebACL", aws_wafv2_web_acl.this.name, "Region", var.region, "Rule", "ALL"],
            [".", "BlockedRequests", ".", ".", ".", ".", ".", "."],
          ]
        }
      },
    ]
  })
}

output "url" { value = "${local.tls ? "https" : "http"}://${local.hostname}" }
output "hostname" { value = local.hostname }
output "dns_name" { value = aws_lb.this.dns_name }
output "arn_suffix" { value = aws_lb.this.arn_suffix }
output "web_acl_arn" { value = aws_wafv2_web_acl.this.arn }
output "access_log_bucket" { value = aws_s3_bucket.logs.id }
