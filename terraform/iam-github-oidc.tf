### GitHub Actions OIDC ###
# GitHub Actions가 고정 AWS 액세스 키 없이 OIDC 토큰으로 이 role을 임시로 assume해서
# 1) 이미지 build & push (ECR)
# 2) ECS 태스크 정의/서비스 갱신 (terraform apply -target으로 ECS 리소스만 재배포)
# 를 수행할 수 있도록 함. .github/workflows/deploy.yml 이 이 role을 사용한다.

variable "github_org" {
  type        = string
  description = "GitHub organization/user (예: cloudduck)"
}
variable "github_repo" {
  type        = string
  description = "GitHub repository 이름 (예: my-repo)"
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
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}*/${var.github_repo}*:ref:refs/heads/main"
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
        Resource = [
          aws_ecr_repository.tf_web_ecr.arn,
          aws_ecr_repository.tf_batch_ecr.arn,
        ]
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
          module.ecs_execution.iam_role_arn,
          module.ecs_task.iam_role_arn,
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
        Resource = [
          aws_ecr_repository.tf_web_ecr.arn,
          aws_ecr_repository.tf_batch_ecr.arn,
        ]
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
          module.ecs_execution.iam_role_arn,
          module.ecs_task.iam_role_arn,
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

# terraform state 백업 위치(S3 backend, main.tf 참고) 접근 권한
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
        Resource = "arn:aws:s3:::ccrew-033177021117-ap-northeast-2-an/clduck/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::ccrew-033177021117-ap-northeast-2-an"
        Condition = {
          StringLike = { "s3:prefix" = "clduck/*" }
        }
      }
    ]
  })
}
