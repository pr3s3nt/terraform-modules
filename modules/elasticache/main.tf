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

# The VPC, its shared private subnets and the EKS node subnets come from the
# completed VPC node of the same Environment (same Connection, account, region).
variable "vpc_id" { type = string }

# The shared private subnets created once by the VPC module (VPC output
# privateSubnetIds). The instance only references them.
variable "private_subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.private_subnet_ids) >= 2 && length(var.private_subnet_ids) <= 4
    error_message = "private_subnet_ids must list the 2 to 4 shared private subnets of the VPC."
  }
}

# The EKS node subnets: the only network source allowed to reach the cache.
variable "subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 2 && length(var.subnet_ids) <= 4
    error_message = "subnet_ids must list the 2 to 4 node subnets of the VPC."
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

# The Definition supplies engine and node size (no module default). ElastiCache
# for Redis OSS 7.1 is the latest Redis OSS engine of the service (later lines
# are Valkey); 7.x supports RBAC users and in-transit encryption.
variable "engine_version" {
  type = string
  validation {
    condition     = contains(["7.0", "7.1"], var.engine_version)
    error_message = "engine_version must be an ElastiCache for Redis OSS 7.x version."
  }
}

variable "node_type" {
  type = string
  validation {
    condition     = contains(["cache.t4g.micro", "cache.t4g.small", "cache.t4g.medium"], var.node_type)
    error_message = "node_type must be cache.t4g.micro, cache.t4g.small or cache.t4g.medium (the small Graviton burstable ElastiCache node types)."
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
  key  = var.tags["orchestrator-instance"]
  name = "orc-${local.key}"
}

data "aws_subnet" "node" {
  count = length(var.subnet_ids)
  id    = var.subnet_ids[count.index]
}

locals {
  client_cidrs = [for s in data.aws_subnet.node : s.cidr_block]
}

resource "aws_elasticache_subnet_group" "this" {
  name       = local.name
  subnet_ids = var.private_subnet_ids
  tags       = { Name = local.name }
}

# Ingress only from the EKS node subnets. No egress rule is declared, so the
# default allow-all egress rule is removed.
resource "aws_security_group" "this" {
  name        = "${local.name}-cache"
  description = "ElastiCache Redis from the EKS node subnets only"
  vpc_id      = var.vpc_id

  ingress {
    description = "Redis TLS from the EKS node subnets"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = local.client_cidrs
  }

  tags = { Name = "${local.name}-cache" }
}

# Redis ACL authentication: the mandatory "default" user is switched off, and
# the application user authenticates with the stable password.
resource "aws_elasticache_user" "default" {
  user_id       = "${local.name}-default"
  user_name     = "default"
  engine        = "redis"
  access_string = "off ~* -@all"

  authentication_mode {
    type = "no-password-required"
  }
}

resource "aws_elasticache_user" "app" {
  user_id       = "${local.name}-app"
  user_name     = var.username
  engine        = "redis"
  access_string = "on ~* +@all"

  authentication_mode {
    type      = "password"
    passwords = [var.password]
  }
}

resource "aws_elasticache_user_group" "this" {
  user_group_id = local.name
  engine        = "redis"
  user_ids      = [aws_elasticache_user.default.user_id, aws_elasticache_user.app.user_id]
}

# One node, no replica, no failover, no snapshot: the smallest compatible
# shape. Encryption in transit (TLS) and at rest are mandatory.
resource "aws_elasticache_replication_group" "this" {
  replication_group_id       = local.name
  description                = "Orchestrator-managed Redis cache"
  engine                     = "redis"
  engine_version             = var.engine_version
  node_type                  = var.node_type
  port                       = 6379
  parameter_group_name       = "default.redis7"
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.this.id]
  user_group_ids             = [aws_elasticache_user_group.this.user_group_id]
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  auto_minor_version_upgrade = false
  snapshot_retention_limit   = 0
  apply_immediately          = true
}

output "host" { value = aws_elasticache_replication_group.this.primary_endpoint_address }
output "port" { value = aws_elasticache_replication_group.this.port }
output "username" { value = aws_elasticache_user.app.user_name }

output "password" {
  value     = var.password
  sensitive = true
}

output "tls" { value = aws_elasticache_replication_group.this.transit_encryption_enabled }
output "replication_group_id" { value = aws_elasticache_replication_group.this.replication_group_id }
output "security_group_id" { value = aws_security_group.this.id }
