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

# Application role (workload-identity output roleName) that gets read/write
# access to this table only.
variable "role_name" { type = string }

variable "hash_key" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{1,255}$", var.hash_key))
    error_message = "hash_key must be a DynamoDB attribute name."
  }
}

variable "hash_key_type" {
  type    = string
  default = "S"
  validation {
    condition     = contains(["S", "N", "B"], var.hash_key_type)
    error_message = "hash_key_type must be S, N or B."
  }
}

# Empty means no sort key.
variable "range_key" {
  type    = string
  default = ""
  validation {
    condition     = var.range_key == "" || can(regex("^[A-Za-z0-9_.-]{1,255}$", var.range_key))
    error_message = "range_key must be empty or a DynamoDB attribute name."
  }
}

variable "range_key_type" {
  type    = string
  default = "S"
  validation {
    condition     = contains(["S", "N", "B"], var.range_key_type)
    error_message = "range_key_type must be S, N or B."
  }
}

# Empty disables time to live.
variable "ttl_attribute" {
  type    = string
  default = ""
}

variable "point_in_time_recovery" {
  type    = bool
  default = true
}

# false enables deletion protection; development Definitions set true.
variable "allow_destroy" {
  type    = bool
  default = false
}

variable "tags" {
  type = map(string)
  validation {
    condition     = can(regex("^[0-9a-f]{8,64}$", lookup(var.tags, "orchestrator-instance", "")))
    error_message = "tags must carry the stable orchestrator-instance key."
  }
}

locals {
  name = "orc-${substr(var.tags["orchestrator-instance"], 0, 32)}"
}

# On-demand capacity, encrypted with the AWS owned key. Reached from the
# application subnets through the VPC gateway endpoint.
resource "aws_dynamodb_table" "this" {
  name                        = local.name
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = var.hash_key
  range_key                   = var.range_key == "" ? null : var.range_key
  deletion_protection_enabled = !var.allow_destroy

  attribute {
    name = var.hash_key
    type = var.hash_key_type
  }

  dynamic "attribute" {
    for_each = var.range_key == "" ? [] : [1]
    content {
      name = var.range_key
      type = var.range_key_type
    }
  }

  dynamic "ttl" {
    for_each = var.ttl_attribute == "" ? [] : [1]
    content {
      attribute_name = var.ttl_attribute
      enabled        = true
    }
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  server_side_encryption {
    enabled = true
  }
}

data "aws_iam_policy_document" "access" {
  statement {
    actions = [
      "dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan",
      "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:BatchWriteItem",
      "dynamodb:ConditionCheckItem", "dynamodb:DescribeTable",
    ]
    resources = [aws_dynamodb_table.this.arn, "${aws_dynamodb_table.this.arn}/index/*"]
  }
}

resource "aws_iam_role_policy" "access" {
  name   = "dynamodb-${local.name}"
  role   = var.role_name
  policy = data.aws_iam_policy_document.access.json
}

output "table_name" { value = aws_dynamodb_table.this.name }
output "table_arn" { value = aws_dynamodb_table.this.arn }
output "region" { value = var.region }
