############################################################
# GitHub Actions OIDC + CI 배포 롤
#
# 왜 메인 terraform/ 이 아니라 여기(bootstrap)에 있나:
#   1) 순환 문제 — CI가 자기 자신의 권한을 만들게 하면, 악의적/실수 PR이 자기 권한을
#      슬쩍 올릴 수 있다. bootstrap은 사람이 직접만 돌리므로 그 경로가 막힌다.
#   2) 생존 주기 — 메인 스택은 destroy/재생성 주기가 있는데, CI의 신원(이 롤)이 거기
#      같이 묶여 있으면 메인이 날아갈 때 CI 복구 수단까지 같이 사라진다.
#      (실제로 2026-08-20에 이 일이 발생해서 CI가 완전히 멈췄고, 그래서 여기로 분리함)
#
# 실행: 사람이 직접. CI에 절대 넣지 말 것.
#   cd terraform-bootstrap && terraform apply
#
# .github/workflows/deploy.yml 이 role 이름(github-actions-ecr-push)을 문자열로
# 참조하므로, 이름을 바꾸면 워크플로우도 같이 고쳐야 한다.
############################################################

variable "github_org" {
  type        = string
  description = "GitHub organization/user"
  default     = "boeunparking"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository 이름"
  default     = "ccrew-repo"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # 메인 스택(terraform/)이 만드는 리소스들의 ARN.
  #
  # data 소스로 "조회"하지 않고 ARN을 문자열로 조립하는 이유:
  # data 소스는 대상이 실제로 존재해야 plan이 통과한다. 그런데 bootstrap은 메인 스택이
  # 아직 없거나(최초 구축) 통째로 destroy된 상태에서도 반드시 apply 가능해야 한다 —
  # 그게 bootstrap의 존재 이유다. ARN 문자열은 대상 존재 여부와 무관하게 항상 유효하고,
  # IAM 정책은 원래 "아직 없는 리소스"를 미리 가리켜도 되기 때문에 이쪽이 맞다.
  ecr_web_arn   = "arn:aws:ecr:ap-northeast-2:${local.account_id}:repository/tf-web-ecr"
  ecr_batch_arn = "arn:aws:ecr:ap-northeast-2:${local.account_id}:repository/tf-batch-ecr"

  ecs_execution_role_arn = "arn:aws:iam::${local.account_id}:role/ecs-execution-role"
  ecs_task_role_arn      = "arn:aws:iam::${local.account_id}:role/ecs-task-role"
  worker_task_role_arn   = "arn:aws:iam::${local.account_id}:role/worker-task-role"

  state_bucket = "ccrew-bootstrap"

  frontend_bucket_name = "cloud-duck-frontend-apne2"
  frontend_bucket_arn  = "arn:aws:s3:::${local.frontend_bucket_name}"

  ##########################################################
  # GitHub OIDC 의 sub 클레임 형식
  #
  # GitHub 는 sub 에 org/repo "이름" 뒤에 불변 숫자 ID 를 붙여서 보낸다:
  #   repo:boeunparking@278609587/ccrew-repo@1332880647:ref:refs/heads/main
  # 이름은 바꾸거나 남에게 넘길 수 있지만 ID 는 안 바뀌므로, 해제된 org 이름을
  # 제3자가 선점해 롤을 탈취하는 걸 막아준다.
  #
  # 확인 방법:
  #   curl https://api.github.com/repos/<org>/<repo>/actions/oidc/customization/sub
  #   → sub_claim_prefix 필드가 실제로 쓰이는 접두사다
  #
  # 이름만 있는 기본 형식도 함께 허용한다 — GitHub 가 둘 중 어느 쪽을 보내든
  # 동작해야 하고, 이 설정이 나중에 되돌아가도 CI 가 멈추지 않게 하기 위해서다.
  #
  # 이름에 "*" 를 붙이는 방식(repo:boeunparking*/ccrew-repo*)으로도 매칭은 되지만
  # 쓰지 않는다. 그 패턴은 "boeunparking" 으로 시작하는 아무 org 의
  # "ccrew-repo" 로 시작하는 아무 레포에나 열려 있어서, 누구나 그런 이름의
  # org/레포를 새로 만들어 이 롤을 assume 할 수 있다.
  ##########################################################
  github_org_id = "278609587"

  repo_ids = {
    ccrew_repo     = "1332880647"
    ccrew_frontend = "1316993984"
  }

  # ccrew-repo: main 브랜치 push 로만 한정
  sub_ccrew_repo = [
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
    "repo:${var.github_org}@${local.github_org_id}/${var.github_repo}@${local.repo_ids.ccrew_repo}:ref:refs/heads/main",
  ]

  # ccrew-frontend: 별도 레포. 브랜치 제한은 워크플로우(on.push.branches)에 맡긴다.
  sub_ccrew_frontend = [
    "repo:${var.github_org}/ccrew-frontend:*",
    "repo:${var.github_org}@${local.github_org_id}/ccrew-frontend@${local.repo_ids.ccrew_frontend}:*",
  ]
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # token.actions.githubusercontent.com 인증서 체인의 루트(ISRG Root X1) SHA1 지문.
  # AWS는 GitHub OIDC provider에 한해 자체 신뢰 저장소로 검증하고 이 값은 형식만 확인하지만,
  # 실제 루트 인증서 지문을 넣어둔다.
  thumbprint_list = [
    "cabd2a79a1076a31f21d253635cb039d4329a5e8",
  ]
}

# main 브랜치로의 push에서 실행되는 워크플로우만 이 role을 assume할 수 있도록 제한
resource "aws_iam_role" "github_actions_deploy" {
  name = "github-actions-ecr-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRoleWithWebIdentity"
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = local.sub_ccrew_repo
          }
        }
      }
    ]
  })
}

# 이미지 build & push
resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "ecr-push"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchGetImage",
        ]
        Resource = [local.ecr_web_arn, local.ecr_batch_arn]
      }
    ]
  })
}

# 새 이미지로 ECS 서비스 재배포 (ECS는 리소스 레벨 제한을 지원하지 않아 Resource "*")
resource "aws_iam_role_policy" "github_actions_ecs_deploy" {
  name = "ecs-redeploy"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:RegisterTaskDefinition",
          "ecs:DeregisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:DescribeServices",
          "ecs:DescribeClusters",
          "ecs:UpdateService",
          "ecs:ListTagsForResource",
          "ecs:TagResource",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          local.ecs_execution_role_arn,
          local.ecs_task_role_arn,
          # batch(worker.js)가 SES 발송용으로 쓰는 전용 task role — notifications.tf가 만든다.
          local.worker_task_role_arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = "elasticloadbalancing:DescribeTargetGroups"
        Resource = "*"
      }
    ]
  })
}

# CI에서 terraform apply -target 실행 시 refresh 단계가 기존 리소스를 읽어야 하므로
# 필요한 Describe/Get 계열 읽기 전용 권한만 부여한다.
resource "aws_iam_role_policy" "github_actions_state_refresh" {
  name = "state-refresh-readonly"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTags",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:ListTagsForResource",
        ]
        Resource = [local.ecr_web_arn, local.ecr_batch_arn]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:GetRolePolicy",
        ]
        Resource = [
          local.ecs_execution_role_arn,
          local.ecs_task_role_arn,
          local.worker_task_role_arn,
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcAttribute",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSecurityGroupRules",
          "ec2:DescribeRouteTables",
          "ec2:DescribeNetworkAcls",
        ]
        Resource = "*"
      }
    ]
  })
}

# CI의 refresh 단계가 읽어야 하는 나머지 리소스들.
#
# 위 state-refresh-readonly에 다 넣지 않고 정책을 나눈 이유: IAM 인라인 정책은 6144자
# 제한이 있어서 한 정책에 계속 얹으면 언젠가 막힌다.
#
# 이 권한들은 2026-08-20 CI 실패에서 실제로 하나씩 확인된 것들이다 — ECS 태스크에
# DB 접속 정보(Secrets Manager)를 연결하면서 terraform이 참조하는 리소스 범위가
# RDS/KMS/ElastiCache까지 넓어졌는데, 기존 정책엔 그 읽기 권한이 없어서 refresh 단계가
# AccessDenied로 전부 실패했다.
resource "aws_iam_role_policy" "github_actions_state_refresh_data" {
  name = "state-refresh-readonly-data"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # RDS: 서브넷 그룹/인스턴스 조회. Describe 계열은 목록 조회라 리소스 스코프
        # 지원이 들쭉날쭉해서 "*" + 읽기 전용으로만 제한한다.
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances",
          "rds:DescribeDBSubnetGroups",
          "rds:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        # ElastiCache(Valkey): 서브넷 그룹 / 복제 그룹 조회
        Effect = "Allow"
        Action = [
          "elasticache:DescribeCacheSubnetGroups",
          "elasticache:DescribeReplicationGroups",
          "elasticache:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        # KMS: RDS 암호화 키(서울/도쿄) 조회. DescribeKey는 키 정책 확인용이라
        # 실제 암복호화 권한(Encrypt/Decrypt)은 주지 않는다.
        Effect = "Allow"
        Action = [
          "kms:DescribeKey",
          "kms:ListResourceTags",
        ]
        Resource = "*"
      },
      {
        # Secrets Manager: 시크릿 "메타데이터"만 조회. GetSecretValue(실제 비밀번호 읽기)는
        # 일부러 제외했다 — CI는 시크릿 ARN을 ECS 태스크에 연결만 하면 되고,
        # 값 자체는 컨테이너 시작 시 ECS execution role이 읽는다.
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
        ]
        Resource = "*"
      },
      {
        # ECR 레지스트리 단위(계정 전체) 복제 설정 — 서울→도쿄 이미지 자동 복제.
        # 레지스트리 단위 설정이라 리소스 스코프 자체를 지원하지 않는다.
        Effect   = "Allow"
        Action   = "ecr:DescribeRegistry"
        Resource = "*"
      }
    ]
  })
}

# terraform state 백업 위치(메인 프로젝트 terraform/main.tf의 S3 backend) 접근 권한
resource "aws_iam_role_policy" "github_actions_tf_state" {
  name = "tf-state-access"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # state 파일 + use_lockfile 락 파일(.tflock) 읽기/쓰기/삭제. 공용 버킷이라 clduck/ 경로로 한정.
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${local.state_bucket}/clduck/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${local.state_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = "clduck/*" }
        }
      }
    ]
  })
}

resource "aws_iam_role" "github_actions_frontend_deploy" {
  name = "github-actions-frontend-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github_actions.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = local.sub_ccrew_frontend
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_frontend_deploy" {
  name = "frontend-deploy-policy"
  role = aws_iam_role.github_actions_frontend_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          local.frontend_bucket_arn,
          "${local.frontend_bucket_arn}/*"
        ]
      },
      {
        # CloudFront distribution ID는 생성 시점에 AWS가 부여하는 값이라 bootstrap에서
        # 미리 알 수 없음 (ECR repo 이름처럼 우리가 미리 정하는 값이 아님).
        # CreateInvalidation은 리소스 레벨 제한 자체가 실용적이지 않아 "*"로 둠.
        Effect   = "Allow"
        Action   = "cloudfront:CreateInvalidation"
        Resource = "*"
      }
    ]
  })
}

output "github_actions_role_arn" {
  description = ".github/workflows/deploy.yml 의 role-to-assume 에 들어가는 값"
  value       = aws_iam_role.github_actions_deploy.arn
}

resource "aws_iam_role_policy_attachment" "github_actions_readonly" {
  role       = aws_iam_role.github_actions_deploy.id
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}


############################################################
# 전체 인프라 apply 전용 롤 (github-actions-terraform)
#
# 왜 위의 github-actions-ecr-push 를 재사용하지 않나:
#   그 롤은 "이미지 푸시 + ECS 태스크 정의 갱신"만 되도록 일부러 좁혀 놓은 것이다.
#   반면 terraform/ 전체 apply 는 VPC/RDS/ElastiCache/IAM/KMS/Secrets Manager/
#   CloudFront/Route53/Lambda/SES/Global Accelerator/WAF/Client VPN 을 전부
#   생성·수정·삭제해야 해서 사실상 계정 전권이 필요하다.
#   그 전권을 기존 롤에 얹으면 좁혀둔 의미가 통째로 사라지므로, "큰 망치"는
#   별도 롤로 분리한다. 워크플로우의 role-to-assume ARN 만 보고 그 잡이 어느
#   권한으로 도는지 구분할 수 있다는 이점도 있다.
#
# 위험 인지 — 이 롤을 assume 할 수 있으면 이 계정에서 사실상 뭐든 할 수 있다:
#   신뢰 정책은 위 롤과 동일하게 ccrew-repo 의 main 브랜치로만 한정한다
#   (local.sub_ccrew_repo). fork PR 이나 다른 브랜치에서는 assume 되지 않는다.
#   바꿔 말하면 "main 에 푸시할 수 있는 사람 = 계정 관리자"가 되므로,
#   GitHub 쪽에서 main 브랜치 보호 규칙(리뷰 필수 / 직접 푸시 금지)을 같이
#   켜 두는 걸 권장한다. 그게 실질적인 최후 방어선이다.
#
# 최소권한 정책을 직접 쓰지 않은 이유:
#   메인 스택은 리소스가 계속 늘어나는데, 그때마다 여기 Action 을 추가하지 않으면
#   apply 가 AccessDenied 로 중간에 멈춘다. terraform 은 부분 실패해도 이미 만든
#   리소스는 state 에 남으므로, 권한 누락은 "실패"가 아니라 "반쯤 배포된 상태"를
#   만든다. 그게 전권보다 위험하다고 판단해 AdministratorAccess 를 쓴다.
############################################################
resource "aws_iam_role" "github_actions_terraform" {
  name = "github-actions-terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRoleWithWebIdentity"
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = local.sub_ccrew_repo
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform_admin" {
  role       = aws_iam_role.github_actions_terraform.id
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "github_actions_terraform_role_arn" {
  description = ".github/workflows/deploy.yml 의 전체 apply 잡이 assume 하는 롤"
  value       = aws_iam_role.github_actions_terraform.arn
}