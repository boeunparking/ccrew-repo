############################################################
# 온프레미스(EC2) IPsec 터널 설정 — libreswan
#
# 원래 strongSwan을 쓰려 했으나 Amazon Linux 2023 기본 저장소에 그 패키지가 없다
# ("No match for argument: strongswan"으로 설치 자체가 실패). AL2023은 RHEL 계열이라
# 표준 IPsec 구현체로 libreswan(4.12)이 들어 있고, 그쪽으로 전환했다.
# 둘 다 IKE/IPsec을 하는 같은 역할이지만 설정 문법이 서로 달라서 그대로 옮길 수 없다.
#
# EC2는 site-to-site-vpn 모듈이 만드는 VPN Connection보다 먼저 생성되므로
# (Customer Gateway가 EC2의 EIP를 필요로 함) 터널 정보(사전공유키 등)를
# user_data로 넣을 수 없다. 대신 VPN Connection 생성 "이후"에
# SSM Run Command로 원격 설치/설정한다.
#
# 주의: 사전공유키가 SSM 명령 파라미터로 전달되어 SSM 실행 이력에 남는다.
#       스모크 테스트 범위를 벗어나면 Secrets Manager 경유로 바꾸는 것을 권장.
############################################################

resource "aws_ssm_association" "libreswan_onprem" {
  name = "AWS-RunShellScript"

  targets {
    key    = "InstanceIds"
    values = [module.onprem.instance_id]
  }

  parameters = {
    commands = join("\n", [
      "set -e",
      "",
      "dnf install -y libreswan",
      "",
      "# libreswan은 /etc/ipsec.conf 가 /etc/ipsec.d/*.conf 를 include 하는 구조라",
      "# 메인 파일을 건드리지 않고 별도 파일로 떨군다.",
      "cat > /etc/ipsec.d/aws-vpn.conf <<'EOF'",
      "conn tunnel1",
      "    authby=secret",
      "    auto=start",
      "    left=%defaultroute",
      "    leftid=${module.onprem.eip_public_ip}",
      "    leftsubnet=${var.onprem_vpc_cidr}",
      "    right=${module.site_to_site_vpn_onprem.tunnel1_address}",
      "    rightsubnet=${var.vpc_cidr_seoul}",
      "    type=tunnel",
      "    # strongSwan의 keyexchange=ikev1 에 해당. libreswan은 기본이 IKEv2라 명시적으로 끈다",
      "    ikev2=no",
      "    # 알고리즘 표기법도 다르다: strongSwan은 aes256-sha1-modp1024! / libreswan은 세미콜론으로 DH 그룹 구분",
      "    ike=aes256-sha1;modp1024",
      "    phase2alg=aes256-sha1",
      "    # EC2는 사설 IP를 가진 채 EIP로 NAT되어 나가므로 NAT-Traversal이 필요하다",
      "    encapsulation=yes",
      "    # 터널이 조용히 끊긴 걸 감지해 자동 복구 (AWS 권장 설정)",
      "    dpddelay=10",
      "    dpdtimeout=30",
      "    dpdaction=restart",
      "    keyingtries=%forever",
      "",
      "conn tunnel2",
      "    authby=secret",
      "    auto=start",
      "    left=%defaultroute",
      "    leftid=${module.onprem.eip_public_ip}",
      "    leftsubnet=${var.onprem_vpc_cidr}",
      "    right=${module.site_to_site_vpn_onprem.tunnel2_address}",
      "    rightsubnet=${var.vpc_cidr_seoul}",
      "    type=tunnel",
      "    ikev2=no",
      "    ike=aes256-sha1;modp1024",
      "    phase2alg=aes256-sha1",
      "    encapsulation=yes",
      "    dpddelay=10",
      "    dpdtimeout=30",
      "    dpdaction=restart",
      "    keyingtries=%forever",
      "EOF",
      "chmod 600 /etc/ipsec.d/aws-vpn.conf",
      "",
      "cat > /etc/ipsec.d/aws-vpn.secrets <<'EOF'",
      "${module.onprem.eip_public_ip} ${module.site_to_site_vpn_onprem.tunnel1_address} : PSK \"${module.site_to_site_vpn_onprem.tunnel1_preshared_key}\"",
      "${module.onprem.eip_public_ip} ${module.site_to_site_vpn_onprem.tunnel2_address} : PSK \"${module.site_to_site_vpn_onprem.tunnel2_preshared_key}\"",
      "EOF",
      "chmod 600 /etc/ipsec.d/aws-vpn.secrets",
      "",
      "# 이 EC2가 온프레미스 라우터 역할을 겸하므로 자기 것이 아닌 패킷도 통과시켜야 한다",
      "sysctl -w net.ipv4.ip_forward=1",
      "echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-vpn-forward.conf",
      "",
      "# libreswan은 인증서 저장소(NSS DB)가 있어야 뜬다. 이미 있으면 아무 일도 안 한다.",
      "ipsec initnss || true",
      "",
      "# 서비스 이름도 strongswan이 아니라 ipsec이다",
      "systemctl enable ipsec",
      "systemctl restart ipsec",
      "",
      "sleep 5",
      "ipsec status || true",
    ])
  }

  depends_on = [module.site_to_site_vpn_onprem]
}
