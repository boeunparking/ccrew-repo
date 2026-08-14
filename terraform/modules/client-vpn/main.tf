########################################
# VPN 접속 로그
########################################
resource "aws_cloudwatch_log_group" "vpn" {
  name              = "/aws/clientvpn/${var.project}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_stream" "vpn" {
  name           = "${var.project}-connections"
  log_group_name = aws_cloudwatch_log_group.vpn.name
}

########################################
# VPN 엔드포인트용 보안그룹
########################################
resource "aws_security_group" "vpn" {
  name        = "${var.project}-client-vpn-sg"
  description = "Client VPN endpoint SG"
  vpc_id      = var.vpc_id

  egress {
    description = "VPN admin to VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-client-vpn-sg" }
}

########################################
# Client VPN Endpoint (Admin → DB)
########################################
resource "aws_ec2_client_vpn_endpoint" "this" {
  description            = "${var.project} admin VPN (DB access)"
  server_certificate_arn = var.server_certificate_arn
  client_cidr_block      = var.client_cidr_block
  split_tunnel           = true # DB 대역만 VPN 경유
  vpc_id                 = var.vpc_id
  security_group_ids     = [aws_security_group.vpn.id]

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = var.client_root_certificate_arn
  }

  connection_log_options {
    enabled               = true
    cloudwatch_log_group  = aws_cloudwatch_log_group.vpn.name
    cloudwatch_log_stream = aws_cloudwatch_log_stream.vpn.name
  }

  tags = { Name = "${var.project}-client-vpn" }
}

########################################
# DB 서브넷에 ENI 연결
########################################
resource "aws_ec2_client_vpn_network_association" "this" {
  count                  = length(var.target_subnet_ids)
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  subnet_id              = var.target_subnet_ids[count.index]
}

########################################
# 인가 규칙: VPN 관리자 → DB 서브넷 (3306은 DB SG에서 제어)
########################################
resource "aws_ec2_client_vpn_authorization_rule" "db" {
  count                  = length(var.authorized_cidrs)
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  target_network_cidr    = var.authorized_cidrs[count.index]
  authorize_all_groups   = true
  description            = "Admin access to DB subnet"
}
