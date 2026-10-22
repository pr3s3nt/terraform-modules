terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.60.0, < 7.0.0"
    }
  }
}

# The Driver Account credential is bound by the executor through the provider
# environment; the module only receives the Definition region and the
# executor-owned platform tags.
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
  default = "10.60.0.0/16"
  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) >= 16 && tonumber(split("/", var.cidr)[1]) <= 18
    error_message = "cidr must be an IPv4 block between /16 and /18."
  }
}

# Explicit availability zones (for example us-east-1a and us-east-1c). One
# public, one application and one database subnet is created in each zone.
variable "availability_zones" {
  type = list(string)
  validation {
    condition     = length(var.availability_zones) >= 2 && length(var.availability_zones) <= 4 && length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "availability_zones must list 2 to 4 distinct zones."
  }
}

# One NAT Gateway for all zones is the cheaper default; false creates one per
# zone so a zone outage does not cut outbound traffic of the others.
variable "single_nat_gateway" {
  type    = bool
  default = true
}

# Executor-owned: stable platform tags of the instance.
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  zones    = length(var.availability_zones)
  nat_size = var.single_nat_gateway ? 1 : local.zones
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = var.name }
}

# The default security group carries no rule, so nothing uses it implicitly.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

# Public subnets (slots 0-3) hold only the public load balancer and the NAT
# Gateways. Nothing here gets a public IP automatically.
resource "aws_subnet" "public" {
  count                   = local.zones
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.cidr, 4, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name}-public-${count.index}", "kubernetes.io/role/elb" = "1" }
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
  count          = local.zones
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = local.nat_size
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_size
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${var.name}-nat-${count.index}" }
  depends_on    = [aws_internet_gateway.this]
}

# Private application subnets (slots 4-7): EKS nodes and the internal load
# balancer. Outbound traffic (Firebase, Windows Notification Service, ECR)
# leaves through the NAT Gateway.
resource "aws_subnet" "app" {
  count                   = local.zones
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.cidr, 4, 4 + count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name}-app-${count.index}", "kubernetes.io/role/internal-elb" = "1" }
}

resource "aws_route_table" "app" {
  count  = local.nat_size
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }
  tags = { Name = "${var.name}-app-${count.index}" }
}

resource "aws_route_table_association" "app" {
  count          = local.zones
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[var.single_nat_gateway ? 0 : count.index].id
}

# Private database subnets (slots 8-11): no route to the Internet at all.
resource "aws_subnet" "db" {
  count                   = local.zones
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.cidr, 4, 8 + count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name}-db-${count.index}" }
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-db" }
}

resource "aws_route_table_association" "db" {
  count          = local.zones
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# Gateway endpoints keep DynamoDB and S3 traffic of the application subnets
# inside the AWS network (no NAT data charge).
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.app[*].id
  tags              = { Name = "${var.name}-dynamodb" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.app[*].id
  tags              = { Name = "${var.name}-s3" }
}

output "id" { value = aws_vpc.this.id }
output "cidr" { value = aws_vpc.this.cidr_block }
# subnetIds keeps the contract name EKS consumes: the private application subnets.
output "subnetIds" { value = tolist(aws_subnet.app[*].id) }
output "privateSubnetIds" { value = tolist(aws_subnet.db[*].id) }
output "publicSubnetIds" { value = tolist(aws_subnet.public[*].id) }
