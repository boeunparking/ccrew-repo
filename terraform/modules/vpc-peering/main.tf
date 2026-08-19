########################################
# 멀티 프로바이더 (같은 리전이면 둘 다 같은 provider 전달)
########################################
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.requester, aws.accepter]
    }
  }
}

########################################
# 피어링 요청 (Site-to-Site VPN 대체)
########################################
resource "aws_vpc_peering_connection" "this" {
  provider    = aws.requester
  vpc_id      = var.requester_vpc_id
  peer_vpc_id = var.accepter_vpc_id
  peer_region = var.accepter_region # null이면 같은 리전
  auto_accept = false

  tags = { Name = "${var.project}-${var.name}-peering" }
}

########################################
# 피어링 수락
########################################
resource "aws_vpc_peering_connection_accepter" "this" {
  provider                  = aws.accepter
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true

  tags = { Name = "${var.project}-${var.name}-peering-accepter" }
}

########################################
# DNS 해석 옵션 (양쪽 모두 활성화)
########################################
resource "aws_vpc_peering_connection_options" "requester" {
  provider                  = aws.requester
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_vpc_peering_connection_options" "accepter" {
  provider                  = aws.accepter
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

########################################
# 라우트: 요청자 → 수락자 CIDR
########################################
resource "aws_route" "requester_to_accepter" {
  provider = aws.requester
  count    = length(var.requester_route_table_ids)

  route_table_id            = var.requester_route_table_ids[count.index]
  destination_cidr_block    = var.accepter_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

########################################
# 라우트: 수락자 → 요청자 CIDR
########################################
resource "aws_route" "accepter_to_requester" {
  provider = aws.accepter
  count    = length(var.accepter_route_table_ids)

  route_table_id            = var.accepter_route_table_ids[count.index]
  destination_cidr_block    = var.requester_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}
