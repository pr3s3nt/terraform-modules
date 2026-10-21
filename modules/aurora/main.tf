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

# Environment-level label (the Definition passes the infrastructure resource
# name). It is only the Name tag: physical identifiers derive from the stable
# instance tag below, so two databases of one Environment never collide.
variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,49}$", var.name))
    error_message = "name must be a lowercase DNS-style label of 3 to 50 characters."
  }
}

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

# The EKS node subnets: the only network source allowed to reach the database.
variable "subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 2 && length(var.subnet_ids) <= 4
    error_message = "subnet_ids must list the 2 to 4 node subnets of the VPC."
  }
}

variable "database" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database)) && var.database != "postgres"
    error_message = "database must be a lowercase identifier other than postgres."
  }
}

variable "username" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,15}$", var.username)) && !contains(["postgres", "rdsadmin", "admin"], var.username)
    error_message = "username must be a lowercase identifier of at most 16 characters and not a reserved name."
  }
}

# Executor-owned: the stable password (one secret-store reference per
# instance, reused across retries) and the stable platform tags.
variable "master_password" {
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

# The Definition supplies engine and sizing (no module default). Aurora
# PostgreSQL 16.14 was verified available in us-east-1 with Serverless v2
# scaling to 0 ACU (minimum 16.3); only the 16.x line is accepted.
variable "engine_version" {
  type = string
  validation {
    condition     = can(regex("^16\\.(1[0-9]|[3-9])$", var.engine_version))
    error_message = "engine_version must be an Aurora PostgreSQL 16.x release that supports scaling to 0 ACU."
  }
}

variable "min_capacity" {
  type = number
  validation {
    condition     = var.min_capacity * 2 == floor(var.min_capacity * 2) && (var.min_capacity == 0 || (var.min_capacity >= 0.5 && var.min_capacity <= 8))
    error_message = "min_capacity must be 0 or a multiple of 0.5 ACU up to 8."
  }
}

variable "max_capacity" {
  type = number
  validation {
    condition     = var.max_capacity * 2 == floor(var.max_capacity * 2) && var.max_capacity >= 1 && var.max_capacity <= 8
    error_message = "max_capacity must be a multiple of 0.5 ACU between 1 and 8."
  }
  # Aurora requires the maximum to be at least the minimum (and above 0.5).
  validation {
    condition     = var.max_capacity >= var.min_capacity
    error_message = "max_capacity must not be lower than min_capacity."
  }
}

variable "seconds_until_auto_pause" {
  type    = number
  default = 3600
  validation {
    condition     = var.seconds_until_auto_pause >= 300 && var.seconds_until_auto_pause <= 86400
    error_message = "seconds_until_auto_pause must be between 300 and 86400."
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

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = var.private_subnet_ids
  tags       = { Name = var.name }
}

# Ingress only from the EKS node subnets. No egress rule is declared, so the
# default allow-all egress rule is removed: the database initiates nothing.
resource "aws_security_group" "this" {
  name        = "${local.name}-db"
  description = "Aurora PostgreSQL from the EKS node subnets only"
  vpc_id      = var.vpc_id

  ingress {
    description = "PostgreSQL from the EKS node subnets"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = local.client_cidrs
  }

  tags = { Name = "${var.name}-db" }
}

# One Aurora Serverless v2 writer on Aurora Standard storage, encrypted with
# the AWS-managed RDS key. No read replica, no I/O-Optimized, no Performance
# Insights, no enhanced monitoring, no log export. Destroy is allowed: the
# resource is deleted only by an admitted, confirmed delete operation.
resource "aws_rds_cluster" "this" {
  cluster_identifier           = local.name
  engine                       = "aurora-postgresql"
  engine_version               = var.engine_version
  database_name                = var.database
  master_username              = var.username
  master_password              = var.master_password
  port                         = 5432
  db_subnet_group_name         = aws_db_subnet_group.this.name
  vpc_security_group_ids       = [aws_security_group.this.id]
  storage_encrypted            = true
  storage_type                 = "aurora"
  backup_retention_period      = 1
  copy_tags_to_snapshot        = true
  skip_final_snapshot          = true
  delete_automated_backups     = true
  deletion_protection          = false
  apply_immediately            = true
  allow_major_version_upgrade  = false
  performance_insights_enabled = false

  serverlessv2_scaling_configuration {
    min_capacity             = var.min_capacity
    max_capacity             = var.max_capacity
    seconds_until_auto_pause = var.min_capacity == 0 ? var.seconds_until_auto_pause : null
  }
}

resource "aws_rds_cluster_instance" "writer" {
  identifier                   = "${local.name}-writer"
  cluster_identifier           = aws_rds_cluster.this.id
  instance_class               = "db.serverless"
  engine                       = aws_rds_cluster.this.engine
  engine_version               = aws_rds_cluster.this.engine_version
  db_subnet_group_name         = aws_db_subnet_group.this.name
  publicly_accessible          = false
  auto_minor_version_upgrade   = false
  performance_insights_enabled = false
  monitoring_interval          = 0
}

output "host" { value = aws_rds_cluster.this.endpoint }
output "port" { value = aws_rds_cluster.this.port }
output "database" { value = aws_rds_cluster.this.database_name }
output "username" { value = aws_rds_cluster.this.master_username }

output "password" {
  value     = var.master_password
  sensitive = true
}
output "cluster_identifier" { value = aws_rds_cluster.this.cluster_identifier }
output "writer_identifier" { value = aws_rds_cluster_instance.writer.identifier }
output "security_group_id" { value = aws_security_group.this.id }
