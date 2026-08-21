############################################################
# 온프레미스 MinIO 설치 + RDS PII(users) 일일 백업
#
# vpn-strongswan.tf와 같은 패턴: EC2가 먼저 뜬 뒤 SSM Run Command로
# 원격 설치한다. user_data를 안 쓰는 이유도 동일 — 이 파일이 참조하는
# module.rds_seoul(비밀번호, 엔드포인트)이 EC2보다 늦게 완성될 수 있어서다.
#
# 하는 일:
#   1. onprem-minio-vol(EBS)을 /data에 마운트하고 MinIO를 systemd 서비스로 설치
#   2. backup 버킷(안에 pii/ 프리픽스)을 만든다
#   3. 매일 KST 03:00, RDS users 테이블을 mysqldump로 떠서 로컬 MinIO에 업로드하는
#      cron 스크립트를 심는다
############################################################

# RDS admin 비밀번호 시크릿을 온프레미스 EC2가 읽을 수 있어야
# mysqldump 접속 정보를 얻을 수 있다.
data "aws_iam_policy_document" "onprem_read_rds_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [module.rds_seoul.secret_arn]
  }
}

resource "aws_iam_role_policy" "onprem_read_rds_secret" {
  name   = "onprem-read-rds-secret"
  role   = module.onprem.role_name
  policy = data.aws_iam_policy_document.onprem_read_rds_secret.json
}

resource "aws_ssm_association" "minio_pii_backup" {
  name = "AWS-RunShellScript"

  targets {
    key    = "InstanceIds"
    values = [module.onprem.instance_id]
  }

  parameters = {
    commands = join("\n", [
      "set -e",
      "",
      "# --- 1) EBS 볼륨 마운트 (Nitro 인스턴스는 /dev/sdf가 /dev/xvdf 또는 /dev/nvme1n1로 보일 수 있다) ---",
      "DEVICE=$(lsblk -ndo NAME,SERIAL | grep -i $(echo vol${module.onprem.minio_volume_id} | sed 's/vol-/vol/') | awk '{print \"/dev/\"$1}' || true)",
      "[ -z \"$DEVICE\" ] && DEVICE=$( [ -e /dev/xvdf ] && echo /dev/xvdf || echo /dev/nvme1n1 )",
      "",
      "mkdir -p /data",
      "if ! blkid \"$DEVICE\" > /dev/null 2>&1; then mkfs -t xfs \"$DEVICE\"; fi",
      "grep -q \"$DEVICE\" /etc/fstab || echo \"$DEVICE /data xfs defaults,nofail 0 2\" >> /etc/fstab",
      "mountpoint -q /data || mount /data",
      "",
      "# --- 2) MinIO 설치 ---",
      "dnf install -y jq mariadb105 cronie || dnf install -y jq mysql cronie",
      "systemctl enable --now crond",
      "if ! id minio-user > /dev/null 2>&1; then useradd -r minio-user; fi",
      "mkdir -p /data/minio/backup/pii",
      "chown -R minio-user:minio-user /data/minio",
      "",
      "if [ ! -f /usr/local/bin/minio ]; then",
      "  curl -sSL https://dl.min.io/server/minio/release/linux-arm64/minio -o /usr/local/bin/minio",
      "  chmod +x /usr/local/bin/minio",
      "fi",
      "if [ ! -f /usr/local/bin/mc ]; then",
      "  curl -sSL https://dl.min.io/client/mc/release/linux-arm64/mc -o /usr/local/bin/mc",
      "  chmod +x /usr/local/bin/mc",
      "fi",
      "",
      "cat > /etc/systemd/system/minio.service <<'EOF'",
      "[Unit]",
      "Description=MinIO",
      "After=network.target data.mount",
      "",
      "[Service]",
      "User=minio-user",
      "Environment=MINIO_ROOT_USER=minioadmin",
      "Environment=MINIO_ROOT_PASSWORD=${random_password.minio_root.result}",
      "ExecStart=/usr/local/bin/minio server /data/minio --address :9000 --console-address :9001",
      "Restart=always",
      "",
      "[Install]",
      "WantedBy=multi-user.target",
      "EOF",
      "",
      "systemctl daemon-reload",
      "systemctl enable minio",
      "systemctl restart minio",
      "sleep 3",
      "",
      "/usr/local/bin/mc alias set local http://localhost:9000 minioadmin '${random_password.minio_root.result}' || true",
      "/usr/local/bin/mc mb -p local/backup/pii || true",
      "",
      "# --- 3) 매일 새벽 3시(KST) RDS users 테이블 백업 ---",
      "cat > /usr/local/bin/pii-backup.sh <<'SCRIPT'",
      "#!/bin/bash",
      "set -euo pipefail",
      "",
      "SECRET=$(aws secretsmanager get-secret-value --region ${var.region_seoul} --secret-id '${module.rds_seoul.secret_arn}' --query SecretString --output text)",
      "DB_USER=$(echo \"$SECRET\" | jq -r .username)",
      "DB_PASS=$(echo \"$SECRET\" | jq -r .password)",
      "DB_HOST=$(echo '${module.rds_seoul.primary_endpoint}' | cut -d: -f1)",
      "",
      "OUT=/tmp/pii-backup-$(date +%Y%m%d).sql.gz",
      "mysqldump -h \"$DB_HOST\" -u \"$DB_USER\" -p\"$DB_PASS\" cloud_duck users | gzip > \"$OUT\"",
      "",
      "/usr/local/bin/mc cp \"$OUT\" local/backup/pii/$(basename \"$OUT\")",
      "rm -f \"$OUT\"",
      "SCRIPT",
      "chmod +x /usr/local/bin/pii-backup.sh",
      "",
      "mkdir -p /etc/cron.d",
      "echo '0 18 * * * root /usr/local/bin/pii-backup.sh >> /var/log/pii-backup.log 2>&1' > /etc/cron.d/pii-backup",
    ])
  }

  depends_on = [
    module.onprem,
    aws_iam_role_policy.onprem_read_rds_secret,
    module.rds_seoul,
  ]
}

resource "random_password" "minio_root" {
  length  = 24
  special = false # MinIO root 비밀번호는 특수문자 제한이 있어 영숫자로 제한
}

resource "aws_secretsmanager_secret" "minio_root" {
  name                    = "${var.project}/onprem/minio-root"
  description             = "MinIO root 계정 (PII 백업 콘솔 접근용)"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "minio_root" {
  secret_id = aws_secretsmanager_secret.minio_root.id
  secret_string = jsonencode({
    username = "minioadmin"
    password = random_password.minio_root.result
  })
}
