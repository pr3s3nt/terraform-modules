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

# The EKS cluster (k8s-cluster output name) and the Environment namespace.
# The EKS Definition must enable the Pod Identity agent (ebs_csi_driver = true).
variable "cluster_name" { type = string }

variable "namespace" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a DNS label."
  }
}

# Workloads rendered by score-k8s run as the namespace default ServiceAccount
# unless they use Vault Agent delivery. The association does not change the
# ServiceAccount object.
variable "service_account" {
  type    = string
  default = "default"
}

# Namespace the application may publish custom CloudWatch metrics to.
variable "metric_namespace" {
  type    = string
  default = "PS"
  validation {
    condition     = can(regex("^[A-Za-z0-9_./#:-]{1,255}$", var.metric_namespace)) && !startswith(var.metric_namespace, "AWS/")
    error_message = "metric_namespace must be a custom CloudWatch namespace (not AWS/...)."
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
  name = "orc-${substr(var.tags["orchestrator-instance"], 0, 24)}-app"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# The application role. S3 and DynamoDB Definitions attach their own scoped
# policies to it; this module grants only custom metric publishing.
resource "aws_iam_role" "this" {
  name               = local.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "metrics" {
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.metric_namespace]
    }
  }
}

resource "aws_iam_role_policy" "metrics" {
  name   = "metrics"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.metrics.json
}

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn
}

output "role_arn" { value = aws_iam_role.this.arn }
output "role_name" { value = aws_iam_role.this.name }
output "metric_namespace" { value = var.metric_namespace }
