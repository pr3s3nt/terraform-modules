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

# Environment-level label used only for the Name tag; physical identifiers
# derive from the stable instance tag, so two databases never collide.
variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,49}$", var.name))
    error_message = "name must be a lowercase DNS-style label of 3 to 50 characters."
  }
}

variable "vpc_id" { type = string }

# The private database subnets of the VPC (VPC output privateSubnetIds).
variable "private_subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.private_subnet_ids) >= 2 && length(var.private_subnet_ids) <= 4
    error_message = "private_subnet_ids must list the 2 to 4 database subnets of the VPC."
  }
}

# The application subnets (VPC output subnetIds): the only network source
# allowed to reach the database.
variable "client_subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.client_subnet_ids) >= 2 && length(var.client_subnet_ids) <= 4
    error_message = "client_subnet_ids must list the 2 to 4 application subnets of the VPC."
  }
}

variable "database" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,63}$", var.database)) && !contains(["mysql", "sys", "information_schema", "performance_schema"], var.database)
    error_message = "database must be a lowercase identifier that is not a MySQL system schema."
  }
}

variable "username" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,15}$", var.username)) && !contains(["admin", "rdsadmin", "root", "mysql"], var.username)
    error_message = "username must be a lowercase identifier of at most 16 characters and not a reserved name."
  }
}

# Executor-owned: the stable generated password and the platform tags.
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

# Aurora MySQL 3 (MySQL 8.0 compatible). Scaling to 0 ACU needs 3.08 or later.
variable "engine_version" {
  type = string
  validation {
    condition     = can(regex("^8\\.0\\.mysql_aurora\\.3\\.(0[89]|[1-9][0-9])\\.[0-9]+$", var.engine_version))
    error_message = "engine_version must be an Aurora MySQL 3.08 or later release such as 8.0.mysql_aurora.3.08.2."
  }
}

variable "port" {
  type    = number
  default = 43306
  validation {
    condition     = var.port >= 1150 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a whole number from 1150 to 65535."
  }
}

variable "min_capacity" {
  type = number
  validation {
    condition     = var.min_capacity * 2 == floor(var.min_capacity * 2) && (var.min_capacity == 0 || (var.min_capacity >= 0.5 && var.min_capacity <= 16))
    error_message = "min_capacity must be 0 or a multiple of 0.5 ACU up to 16."
  }
}

variable "max_capacity" {
  type = number
  validation {
    condition     = var.max_capacity * 2 == floor(var.max_capacity * 2) && var.max_capacity >= 1 && var.max_capacity <= 64
    error_message = "max_capacity must be a multiple of 0.5 ACU between 1 and 64."
  }
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

# Writer plus readers; readers spread over the zones of the subnet group.
variable "instance_count" {
  type    = number
  default = 1
  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 3 && floor(var.instance_count) == var.instance_count
    error_message = "instance_count must be 1, 2 or 3."
  }
}

variable "backup_retention_days" {
  type    = number
  default = 7
  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be from 1 to 35."
  }
}

variable "log_retention_days" {
  type    = number
  default = 30
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch Logs retention value."
  }
}

# Slow queries above this many seconds are written to the slowquery log.
variable "long_query_time" {
  type    = number
  default = 2
}

# false keeps a final snapshot and blocks deletion; development Definitions set
# true so the platform cleanup can remove the cluster.
variable "allow_destroy" {
  type    = bool
  default = false
}

variable "create_dashboard" {
  type    = bool
  default = true
}

locals {
  key  = var.tags["orchestrator-instance"]
  name = "orc-${substr(local.key, 0, 24)}"
  logs = ["error", "slowquery"]
}

data "aws_subnet" "client" {
  count = length(var.client_subnet_ids)
  id    = var.client_subnet_ids[count.index]
}

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = var.private_subnet_ids
  tags       = { Name = var.name }
}

# Ingress only from the application subnets on the database port. No egress
# rule: the database initiates nothing.
resource "aws_security_group" "this" {
  name        = "${local.name}-mysql"
  description = "Aurora MySQL from the application subnets only"
  vpc_id      = var.vpc_id

  ingress {
    description = "MySQL from the application subnets"
    from_port   = var.port
    to_port     = var.port
    protocol    = "tcp"
    cidr_blocks = [for s in data.aws_subnet.client : s.cidr_block]
  }

  tags = { Name = "${var.name}-mysql" }
}

resource "aws_rds_cluster_parameter_group" "this" {
  name        = local.name
  family      = "aurora-mysql8.0"
  description = "Slow query log for ${var.name}"

  parameter {
    name  = "slow_query_log"
    value = "1"
  }
  parameter {
    name  = "long_query_time"
    value = tostring(var.long_query_time)
  }
  parameter {
    name  = "log_output"
    value = "FILE"
  }
  parameter {
    name  = "require_secure_transport"
    value = "ON"
  }
}

# The log groups are created before the cluster so retention applies and the
# platform cleanup removes them together with the database.
resource "aws_cloudwatch_log_group" "this" {
  for_each          = toset(local.logs)
  name              = "/aws/rds/cluster/${local.name}/${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_rds_cluster" "this" {
  cluster_identifier              = local.name
  engine                          = "aurora-mysql"
  engine_version                  = var.engine_version
  database_name                   = var.database
  master_username                 = var.username
  master_password                 = var.master_password
  port                            = var.port
  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.this.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name
  enabled_cloudwatch_logs_exports = local.logs
  storage_encrypted               = true
  backup_retention_period         = var.backup_retention_days
  copy_tags_to_snapshot           = true
  skip_final_snapshot             = var.allow_destroy
  final_snapshot_identifier       = var.allow_destroy ? null : "${local.name}-final"
  delete_automated_backups        = var.allow_destroy
  deletion_protection             = !var.allow_destroy
  apply_immediately               = true
  allow_major_version_upgrade     = false

  serverlessv2_scaling_configuration {
    min_capacity             = var.min_capacity
    max_capacity             = var.max_capacity
    seconds_until_auto_pause = var.min_capacity == 0 ? var.seconds_until_auto_pause : null
  }

  depends_on = [aws_cloudwatch_log_group.this]
}

resource "aws_rds_cluster_instance" "this" {
  count                      = var.instance_count
  identifier                 = "${local.name}-${count.index}"
  cluster_identifier         = aws_rds_cluster.this.id
  instance_class             = "db.serverless"
  engine                     = aws_rds_cluster.this.engine
  engine_version             = aws_rds_cluster.this.engine_version
  db_subnet_group_name       = aws_db_subnet_group.this.name
  publicly_accessible        = false
  auto_minor_version_upgrade = false
}

resource "aws_cloudwatch_dashboard" "this" {
  count          = var.create_dashboard ? 1 : 0
  dashboard_name = "${local.name}-aurora"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Aurora CPU and capacity"
          region = var.region
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", local.name],
            [".", "ServerlessDatabaseCapacity", ".", "."],
            [".", "ACUUtilization", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Aurora connections and latency"
          region = var.region
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", local.name],
            [".", "SelectLatency", ".", "."],
            [".", "CommitLatency", ".", "."],
          ]
        }
      },
      {
        type = "log", x = 0, y = 6, width = 24, height = 8
        properties = {
          title  = "Aurora error and slow query log"
          region = var.region
          query  = "SOURCE '${aws_cloudwatch_log_group.this["error"].name}' | SOURCE '${aws_cloudwatch_log_group.this["slowquery"].name}' | fields @timestamp, @log, @message | sort @timestamp desc | limit 100"
          view   = "table"
        }
      },
    ]
  })
}

output "host" { value = aws_rds_cluster.this.endpoint }
output "reader_host" { value = aws_rds_cluster.this.reader_endpoint }
output "port" { value = aws_rds_cluster.this.port }
output "database" { value = aws_rds_cluster.this.database_name }
output "username" { value = aws_rds_cluster.this.master_username }

output "password" {
  value     = var.master_password
  sensitive = true
}

output "jdbc_url" {
  value = "jdbc:mysql://${aws_rds_cluster.this.endpoint}:${aws_rds_cluster.this.port}/${aws_rds_cluster.this.database_name}?sslMode=REQUIRED"
}
output "cluster_identifier" { value = aws_rds_cluster.this.cluster_identifier }
output "security_group_id" { value = aws_security_group.this.id }
