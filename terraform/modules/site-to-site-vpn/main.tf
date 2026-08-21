########################################
# Site-to-Site VPN — 서울 VPC ↔ 온프레미스(실제로는 같은 계정의 EC2)
# VPC Peering을 대체. 온프레미스 쪽에 실제 라우터가 없으므로
# module.onprem 이 만든 EC2가 libreswan으로 터널을 종단해 그 역할을 겸한다.
########################################

########################################
# 1. Virtual Private Gateway — 서울 VPC 쪽 AWS 종단
########################################
resource "aws_vpn_gateway" "this" {
  vpc_id = var.seoul_vpc_id

  tags = { Name = "${var.project}-${var.name}-vgw" }
}

# 서울 라우팅 테이블에 온프레미스 대역 경로를 자동으로 전파
resource "aws_vpn_gateway_route_propagation" "seoul" {
  count = length(var.seoul_route_table_ids)

  vpn_gateway_id = aws_vpn_gateway.this.id
  route_table_id = var.seoul_route_table_ids[count.index]
}

########################################
# 2. Customer Gateway — 온프레미스 쪽 종단(EC2의 고정 공인 IP)
########################################
resource "aws_customer_gateway" "this" {
  bgp_asn    = var.customer_gateway_bgp_asn
  ip_address = var.customer_gateway_ip
  type       = "ipsec.1"

  tags = { Name = "${var.project}-${var.name}-cgw" }
}

########################################
# 3. VPN Connection — IPSec 터널 2개 (정적 라우팅)
#    온프레미스 EC2가 BGP 라우터가 아니므로 static_routes_only = true
########################################
resource "aws_vpn_connection" "this" {
  vpn_gateway_id      = aws_vpn_gateway.this.id
  customer_gateway_id = aws_customer_gateway.this.id
  type                = "ipsec.1"
  static_routes_only  = true

  tags = { Name = "${var.project}-${var.name}-vpn" }
}

resource "aws_vpn_connection_route" "onprem" {
  vpn_connection_id      = aws_vpn_connection.this.id
  destination_cidr_block = var.onprem_cidr
}
