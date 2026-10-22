terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.60.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

variable "region" { type = string }

variable "vpc_id" { type = string }

# The private application subnets of the VPC (VPC output subnetIds).
variable "subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must list at least two application subnets."
  }
}

variable "idle_timeout" {
  type    = number
  default = 60
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

data "aws_vpc" "this" {
  id = var.vpc_id
}

locals {
  name = "orc-${substr(var.tags["orchestrator-instance"], 0, 16)}-int"
}

# Reachable only from inside the VPC (the gateway workload). internal-route
# resources add their own egress rule to the cluster nodes.
resource "aws_security_group" "this" {
  name        = local.name
  description = "Internal ALB reachable from inside the VPC"
  vpc_id      = var.vpc_id
  tags        = { Name = local.name }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = data.aws_vpc.this.cidr_block
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_lb" "this" {
  name                       = local.name
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = var.subnet_ids
  security_groups            = [aws_security_group.this.id]
  idle_timeout               = var.idle_timeout
  drop_invalid_header_fields = true
}

# Unmatched paths get 404; each internal-route adds a path rule.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\":\"no route\"}"
      status_code  = "404"
    }
  }
}

resource "aws_cloudwatch_dashboard" "this" {
  count          = var.create_dashboard ? 1 : 0
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Internal ALB requests and errors"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.this.arn_suffix],
            [".", "HTTPCode_ELB_4XX_Count", ".", "."],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Internal ALB latency"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "p95" }],
            ["...", { stat = "Average" }],
          ]
        }
      },
    ]
  })
}

output "url" { value = "http://${aws_lb.this.dns_name}" }
output "dns_name" { value = aws_lb.this.dns_name }
output "listener_arn" { value = aws_lb_listener.http.arn }
output "security_group_id" { value = aws_security_group.this.id }
output "arn_suffix" { value = aws_lb.this.arn_suffix }
