terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.60.0, < 7.0.0"
    }
  }
}

# The Environment AWS Connection (account, credential and region) is bound by
# the executor through the provider environment; the module only receives the
# executor-pinned region and the stable platform tags.
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

variable "cidr" {
  type    = string
  default = "10.42.0.0/16"
  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) >= 16 && tonumber(split("/", var.cidr)[1]) <= 20
    error_message = "cidr must be an IPv4 block between /16 and /20."
  }
}

variable "az_count" {
  type    = number
  default = 2
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4 && floor(var.az_count) == var.az_count
    error_message = "az_count must be a whole number from 2 to 4."
  }
}

# Executor-owned: stable platform tags of the instance.
variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = var.name }
}

# The default security group of the VPC carries no rule: nothing in the VPC
# can use it implicitly. EKS, Aurora and ElastiCache create their own groups.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

# Public subnets carry only the EKS nodes. A NAT Gateway is the most expensive
# item in a short-lived VPC, so the nodes reach ECR and the EKS API through the
# Internet Gateway with a public IPv4 address each. Aurora and ElastiCache never
# live here: they use the shared private subnets below. No load-balancer subnet
# tag is set, so no public load balancer is discovered by accident.
resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.cidr, 4, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# The single shared private network of the Environment/generation, created once
# in this state: one subnet per availability zone of the node subnets (slots 8 and
# up of the CIDR space; node subnets use slots 0 to 3) and one route table with
# no route to an Internet Gateway or NAT. Aurora/ElastiCache instances receive the
# subnet IDs through the VPC outputs, keep their own subnet group and security
# group, and never create a subnet or CIDR. Deleting a consumer leaves this
# network; it is destroyed only with the VPC after all consumers are gone.
resource "aws_subnet" "private" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.cidr, 4, 8 + count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name}-private-${count.index}" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

output "id" { value = aws_vpc.this.id }
output "cidr" { value = aws_vpc.this.cidr_block }
output "subnetIds" { value = tolist(aws_subnet.public[*].id) }
output "privateSubnetIds" { value = tolist(aws_subnet.private[*].id) }
