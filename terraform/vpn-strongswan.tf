############################################################
# 온프레미스(EC2) strongSwan 설정
#
# EC2는 site-to-site-vpn 모듈이 만드는 VPN Connection보다 먼저 생성되므로
# (Customer Gateway가 EC2의 EIP를 필요로 함) 터널 정보(사전공유키 등)를
# user_data로 넣을 수 없다. 대신 VPN Connection 생성 "이후"에
# SSM Run Command로 strongSwan을 원격 설치/설정한다.
#
# 주의: 사전공유키가 SSM 명령 파라미터로 전달되어 SSM 실행 이력에 남는다.
#       스모크 테스트 범위를 벗어나면 Secrets Manager 경유로 바꾸는 것을 권장.
############################################################

resource "aws_ssm_association" "strongswan_onprem" {
  name = "AWS-RunShellScript"

  targets {
    key    = "InstanceIds"
    values = [module.onprem.instance_id]
  }

  parameters = {
    commands = join("\n", [
      "dnf install -y strongswan || (echo 'strongswan 패키지를 찾을 수 없습니다. EPEL/추가 저장소 필요' && exit 1)",
      "",
      "cat > /etc/strongswan/ipsec.conf <<'EOF'",
      "config setup",
      "",
      "conn tunnel1",
      "  auto=start",
      "  left=%defaultroute",
      "  leftid=${module.onprem.eip_public_ip}",
      "  leftsubnet=${var.onprem_vpc_cidr}",
      "  right=${module.site_to_site_vpn_onprem.tunnel1_address}",
      "  rightsubnet=${var.vpc_cidr_seoul}",
      "  ike=aes256-sha1-modp1024!",
      "  esp=aes256-sha1!",
      "  keyexchange=ikev1",
      "  type=tunnel",
      "  authby=secret",
      "",
      "conn tunnel2",
      "  auto=start",
      "  left=%defaultroute",
      "  leftid=${module.onprem.eip_public_ip}",
      "  leftsubnet=${var.onprem_vpc_cidr}",
      "  right=${module.site_to_site_vpn_onprem.tunnel2_address}",
      "  rightsubnet=${var.vpc_cidr_seoul}",
      "  ike=aes256-sha1-modp1024!",
      "  esp=aes256-sha1!",
      "  keyexchange=ikev1",
      "  type=tunnel",
      "  authby=secret",
      "EOF",
      "",
      "cat > /etc/strongswan/ipsec.secrets <<'EOF'",
      "${module.onprem.eip_public_ip} ${module.site_to_site_vpn_onprem.tunnel1_address} : PSK \"${module.site_to_site_vpn_onprem.tunnel1_preshared_key}\"",
      "${module.onprem.eip_public_ip} ${module.site_to_site_vpn_onprem.tunnel2_address} : PSK \"${module.site_to_site_vpn_onprem.tunnel2_preshared_key}\"",
      "EOF",
      "",
      "sysctl -w net.ipv4.ip_forward=1",
      "echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-vpn-forward.conf",
      "",
      "systemctl enable strongswan",
      "systemctl restart strongswan",
    ])
  }

  depends_on = [module.site_to_site_vpn_onprem]
}
