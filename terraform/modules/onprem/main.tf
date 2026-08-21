########################################
# 온프레미스(로 표기된) 스택 — 서울 리전 ap-northeast-2b
# MinIO 백업 서버 1대 + 전용 VPC
# 서울 ↔ 온프레미스 연결은 루트의 module "site_to_site_vpn_onprem" (Site-to-Site VPN)이 담당.
# 이 모듈이 만드는 EIP를 물고 있는 EC2가 libreswan으로 터널을 종단한다 (vpn-libreswan.tf).
########################################

########################################
# 1. VPC (onprem-vpc, 10.0.0.0/16)
########################################
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "onprem-vpc" }
}

########################################
# 2. Subnet (onprem-sn1, ap-northeast-2b)
########################################
resource "aws_subnet" "sn1" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.subnet_cidr_block
  availability_zone       = var.az_name
  map_public_ip_on_launch = true # 최초 패키지 설치(MinIO 등)용 — 설치 후 축소 권장

  tags = { Name = "onprem-sn1" }
}

########################################
# 3. Internet Gateway (onprem-igw)
#    최초 패키지 설치용. 설치 후 아웃바운드 축소 권장
########################################
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "onprem-igw" }
}

########################################
# 4. Route Table (onprem-rt1)
#    0.0.0.0/0 → IGW 만 여기서 생성.
#    172.16.0.0/16(서울) 방향은 VPC 라우팅 테이블에 경로를 추가하지 않는다 —
#    EC2 위 libreswan이 IPSec 정책(SPD) 레벨에서 터널링을 처리하므로 불필요.
########################################
resource "aws_route_table" "rt1" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "onprem-rt1" }
}

resource "aws_route" "default_igw" {
  route_table_id         = aws_route_table.rt1.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

########################################
# 5. Route Table Association (sn1 ↔ rt1)
########################################
resource "aws_route_table_association" "sn1" {
  subnet_id      = aws_subnet.sn1.id
  route_table_id = aws_route_table.rt1.id
}

########################################
# 6. Security Group (tf-onprem-app-sg)
#    Inbound: 서울 VPC(172.16.0.0/16)만 허용
#    Outbound: 설치 단계에서는 전체 허용 — 설치 후 온프레미스↔서울 트래픽만 남기고 축소 권장
########################################
resource "aws_security_group" "app" {
  name        = "tf-onprem-app-sg"
  description = "MinIO backup server - allow from seoul VPC only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "tf-onprem-app-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "from_seoul" {
  security_group_id = aws_security_group.app.id
  description       = "All traffic from seoul VPC"
  cidr_ipv4         = var.seoul_vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "Package install - tighten after setup"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

########################################
# 6-1. Site-to-Site VPN 터널 트래픽
#      AWS 쪽 터널 엔드포인트 2개는 리전 내 동적 공인 IP라 사전에 고정할 수 없어
#      IKE/ESP 표준 포트로만 허용을 좁힌다 (실제 고객 라우터 방화벽 정책과 동일한 접근)
########################################
resource "aws_vpc_security_group_ingress_rule" "vpn_ike" {
  security_group_id = aws_security_group.app.id
  description       = "IKE (IPSec key exchange) from AWS VPN tunnel endpoints"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 500
  to_port           = 500
}

resource "aws_vpc_security_group_ingress_rule" "vpn_nat_t" {
  security_group_id = aws_security_group.app.id
  description       = "IPSec NAT-Traversal from AWS VPN tunnel endpoints"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 4500
  to_port           = 4500
}

resource "aws_vpc_security_group_ingress_rule" "vpn_esp" {
  security_group_id = aws_security_group.app.id
  description       = "ESP (encrypted IPSec payload) from AWS VPN tunnel endpoints"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "50" # ESP
}

########################################
# 7. NACL (tf-onprem-nacl) — 서브넷 단위 방어선
########################################
resource "aws_network_acl" "this" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = [aws_subnet.sn1.id]

  tags = { Name = "tf-onprem-nacl" }
}

# 서울 VPC → 온프레미스 (MinIO 9000 등 전 포트)
resource "aws_network_acl_rule" "in_from_seoul" {
  network_acl_id = aws_network_acl.this.id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.seoul_vpc_cidr
  from_port      = 0
  to_port        = 65535
}

# 패키지 설치 응답 트래픽 (아웃바운드 443 요청에 대한 리턴)
resource "aws_network_acl_rule" "in_ephemeral" {
  network_acl_id = aws_network_acl.this.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

# 아웃바운드: 설치 단계 전체 허용 — 설치 후 축소 권장
resource "aws_network_acl_rule" "out_all" {
  network_acl_id = aws_network_acl.this.id
  rule_number    = 100
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 65535
}

########################################
# 8. IAM Role / Instance Profile (onprem-app-role)
#    SSM Session Manager 접속용 (키페어 대체)
########################################
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "onprem-app-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = { Name = "onprem-app-role" }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "onprem-app-profile"
  role = aws_iam_role.app.name
}

########################################
# 9. EC2 Instance (onprem-app-ec2) — MinIO
########################################
data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-arm64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023_arm.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.sn1.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  # Site-to-Site VPN에서 이 인스턴스가 IPSec 터널을 종단하는 "고객 게이트웨이" 겸
  # 온프레미스 라우터 역할을 하므로, 자기 것이 아닌 트래픽(터널로 오가는 패킷)도
  # 통과시킬 수 있어야 한다. AWS 기본값(활성화)은 이를 막는다.
  source_dest_check = false

  tags = { Name = "onprem-app-ec2" }
}

########################################
# 9-1. Elastic IP — Customer Gateway가 식별할 고정 퍼블릭 IP
#      (진짜 온프레미스라면 이미 있는 라우터의 공인 IP에 해당)
########################################
resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = { Name = "onprem-app-eip" }
}

########################################
# 10. EBS Volume (onprem-minio-vol) + Attachment
#     MinIO 데이터(backup/, backup/pii/)용
########################################
resource "aws_ebs_volume" "minio" {
  availability_zone = var.az_name
  size              = var.minio_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name     = "onprem-minio-vol"
    Snapshot = "daily" # DLM 대상 태그
  }
}

resource "aws_volume_attachment" "minio" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.minio.id
  instance_id = aws_instance.app.id
}

########################################
# 11. DLM — EBS 일일 스냅샷 ("백업의 백업")
#     매일 KST 02:00 (UTC 17:00) 스냅샷, 최근 N개 보존
########################################
data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "onprem-dlm-role"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "minio_backup" {
  description        = "tf-onprem-minio-backup-plan - daily snapshot of MinIO volume"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags = {
      Snapshot = "daily"
    }

    schedule {
      name = "daily-kst-0200"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["17:00"] # UTC 17:00 = KST 02:00
      }

      retain_rule {
        count = var.snapshot_retain_count
      }

      copy_tags = true
    }
  }

  tags = { Name = "tf-onprem-minio-backup-plan" }
}
