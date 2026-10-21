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

variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,49}$", var.name))
    error_message = "name must be a lowercase DNS-style label of 3 to 50 characters."
  }
}

variable "subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS needs subnets in at least two availability zones."
  }
}

# Only Kubernetes versions in EKS standard support on 2026-10-13 are accepted
# (1.34 ends 2026-12-02), so a cluster never silently bills extended support.
variable "kubernetes_version" {
  type = string
  validation {
    condition     = contains(["1.34", "1.35", "1.36", "1.37"], var.kubernetes_version)
    error_message = "kubernetes_version must be a standard-support EKS version of this release (1.34 to 1.37)."
  }
}

# Public API allowlist, set by the PE/Admin in the Resource Definition (never a
# Workload param). Only specific IPv4 hosts as /32; no default, no 0.0.0.0/0,
# nothing is added automatically. The executor preflight must find its own
# egress IP in this list before a run; this validation cannot prove that.
variable "public_access_cidrs" {
  type     = list(string)
  nullable = false
  validation {
    condition     = length(var.public_access_cidrs) >= 1 && length(var.public_access_cidrs) <= 40 && length(distinct(var.public_access_cidrs)) == length(var.public_access_cidrs)
    error_message = "public_access_cidrs must list 1 to 40 distinct addresses."
  }
  validation {
    condition = alltrue([
      for c in var.public_access_cidrs :
      can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/32$", c)) && can(cidrhost(c, 0)) && c != "0.0.0.0/32"
    ])
    error_message = "public_access_cidrs entries must be valid IPv4 hosts written as a.b.c.d/32 (never 0.0.0.0/0 or a wider prefix)."
  }
}

variable "node_instance_type" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]*\\.[a-z0-9]+$", var.node_instance_type))
    error_message = "node_instance_type must be an EC2 instance type such as t4g.small."
  }
}

variable "node_capacity_type" {
  type = string
  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_disk_size" {
  type = number
  validation {
    condition     = var.node_disk_size >= 20 && var.node_disk_size <= 100 && floor(var.node_disk_size) == var.node_disk_size
    error_message = "node_disk_size must be a whole number of GiB from 20 to 100."
  }
}

variable "node_ami_type" {
  type = string
  validation {
    condition     = contains(["AL2023_x86_64_STANDARD", "AL2023_ARM_64_STANDARD"], var.node_ami_type)
    error_message = "node_ami_type must be an Amazon Linux 2023 standard AMI type."
  }
}

# Exact add-on builds, never resolved to a service default at execution. Both
# were checked on 2026-10-13 with `aws eks describe-addon-versions` against every
# Kubernetes version this module accepts (1.34, 1.35, 1.36, 1.37). A new build
# needs a new packaged release revision.
locals {
  ebs_csi_driver_version     = "v1.66.0-eksbuild.1"
  pod_identity_agent_version = "v1.4.0-eksbuild.4"
}

# In-cluster Redis/PostgreSQL (V2-A03) bind EBS volumes, which Kubernetes 1.35
# can provision only through the EBS CSI driver. Off by default; a Definition
# turns it on explicitly. The driver gets its own run-owned role through EKS Pod
# Identity (not the node role).
variable "ebs_csi_driver" {
  type    = bool
  default = false
}

# Executor-owned: stable platform tags of the instance.
variable "tags" {
  type    = map(string)
  default = {}
}

# The credential that runs the module is the principal the Kubernetes modules
# use through the completed EKS target (the same Environment AWS Connection).
# For an assumed role the session context resolves the role ARN, for an IAM
# user it is the user ARN itself.
data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Run-owned roles with only the AWS-managed policies EKS and the managed node
# group need. Nothing else is attached; the roles belong to this state.
resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# One standard-support control plane with API-only access (no aws-auth
# ConfigMap). The creator is not given implicit admin: the execution principal
# gets an explicit access entry below, owned by this state. The API endpoint is
# public only to the allowlisted executor addresses (the executor is outside the
# VPC) and also private for the nodes.
resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  enabled_cluster_log_types = []

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_access_entry" "execution" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = data.aws_iam_session_context.current.issuer_arn
  type          = "STANDARD"
}

# Cluster-scoped admin is the least built-in access policy that can create the
# run namespace; the entry is deleted with the cluster.
resource "aws_eks_access_policy_association" "execution" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.execution.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.node_instance_type]
  capacity_type   = var.node_capacity_type
  disk_size       = var.node_disk_size
  ami_type        = var.node_ami_type

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_eks_access_policy_association.execution,
  ]
}

data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  count              = var.ebs_csi_driver ? 1 : 0
  name               = "${var.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count      = var.ebs_csi_driver ? 1 : 0
  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "pod_identity_agent" {
  count                       = var.ebs_csi_driver ? 1 : 0
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = local.pod_identity_agent_version
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "ebs_csi" {
  count                       = var.ebs_csi_driver ? 1 : 0
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = local.ebs_csi_driver_version
  resolve_conflicts_on_create = "OVERWRITE"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi[0].arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [aws_eks_addon.pod_identity_agent, aws_iam_role_policy_attachment.ebs_csi]
}

output "name" { value = aws_eks_cluster.this.name }
output "endpoint" { value = aws_eks_cluster.this.endpoint }
output "cluster_security_group_id" { value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id }
output "node_group_name" { value = aws_eks_node_group.this.node_group_name }
output "node_role_arn" { value = aws_iam_role.node.arn }
