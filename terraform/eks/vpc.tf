# =============================================================================
# Network
# =============================================================================
# TWO AVAILABILITY ZONES IS A HARD EKS REQUIREMENT, not a resilience preference.
# The control plane places its network interfaces in at least two subnets in two
# zones and refuses to create otherwise. main.tf at the repository root creates
# ONE public subnet, which is correct for one EC2 host and cannot serve here.
#
# NODES GO IN PRIVATE SUBNETS. A node with a public IP is a node reachable from
# the internet, and nothing in this stack needs that. Outbound traffic - image
# pulls, the EKS API, Let's Encrypt - leaves through the NAT gateway.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "lgtm" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.cluster_name}-vpc" }
}

resource "aws_internet_gateway" "lgtm" {
  vpc_id = aws_vpc.lgtm.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

# THE SUBNET TAGS ARE LOAD-BEARING. The AWS load balancer controller reads them
# to decide where to put a load balancer, and it reports nothing useful when they
# are absent: an internal Service of type LoadBalancer simply stays <pending>
# forever with an event that names no cause.
resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.lgtm.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.cluster_name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.lgtm.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = {
    Name                              = "${var.cluster_name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ONE NAT GATEWAY, NOT ONE PER ZONE. A NAT gateway costs about $32/month plus
# data processing, so two of them double a fixed cost to buy zone-independent
# egress that this stack does not need. The trade is stated rather than hidden:
# if this zone fails, the nodes in the other zone lose outbound internet.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.cluster_name}-nat" }
}

resource "aws_nat_gateway" "lgtm" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.cluster_name}-nat" }

  depends_on = [aws_internet_gateway.lgtm]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lgtm.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lgtm.id
  }

  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lgtm.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lgtm.id
  }

  tags = { Name = "${var.cluster_name}-private" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# S3 GATEWAY ENDPOINT. Tempo and Mimir write blocks to S3 continuously. Without
# this endpoint every one of those bytes leaves through the NAT gateway and is
# billed at the NAT data-processing rate. The endpoint itself is free, and
# s3-backends.tf at the repository root records the same reasoning for the EC2
# plane. This is the single largest cost item this file removes.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.lgtm.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.cluster_name}-s3" }
}
