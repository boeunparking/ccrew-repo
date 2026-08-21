output "vpn_connection_id" {
  value = aws_vpn_connection.this.id
}

output "vpn_gateway_id" {
  value = aws_vpn_gateway.this.id
}

# 온프레미스 EC2에서 libreswan을 설정할 때 필요한 두 터널의 접속 정보.
# preshared_key는 민감정보라 state에는 남지만(암호화 필요) outputs 자체에는
# sensitive 처리해 CLI 출력/로그에 노출되지 않게 한다.
output "tunnel1_address" {
  value = aws_vpn_connection.this.tunnel1_address
}

output "tunnel1_preshared_key" {
  value     = aws_vpn_connection.this.tunnel1_preshared_key
  sensitive = true
}

output "tunnel1_cgw_inside_address" {
  value = aws_vpn_connection.this.tunnel1_cgw_inside_address
}

output "tunnel1_vgw_inside_address" {
  value = aws_vpn_connection.this.tunnel1_vgw_inside_address
}

output "tunnel2_address" {
  value = aws_vpn_connection.this.tunnel2_address
}

output "tunnel2_preshared_key" {
  value     = aws_vpn_connection.this.tunnel2_preshared_key
  sensitive = true
}

output "tunnel2_cgw_inside_address" {
  value = aws_vpn_connection.this.tunnel2_cgw_inside_address
}

output "tunnel2_vgw_inside_address" {
  value = aws_vpn_connection.this.tunnel2_vgw_inside_address
}
