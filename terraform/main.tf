terraform {
  # GitHub Actions(CI)에서도 terraform apply를 실행하므로 state를 로컬이 아닌 S3에 둔다.
  # 기존 ccrew-bootstrap 버킷을 재사용하고, clduck/ 경로 밑에만 state를 둔다.
  # use_lockfile: Terraform 1.10+ 부터 지원되는 S3 자체 락 (DynamoDB 테이블 불필요)
  backend "s3" {
    bucket       = "ccrew-bootstrap"
    key          = "clduck/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.53.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Grafana 대시보드/데이터소스는 AWS API 로 만들 수 없다 — 워크스페이스라는 그릇까지가
    # AWS 담당이고, 그 안의 내용물은 Grafana 자체 HTTP API 영역이다. 그래서 provider 를 하나 더 쓴다.
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.18"
    }
    # 위 Grafana provider 인증에 쓰는 서비스 계정 토큰은 최대 30일짜리다.
    # 만료되면 대시보드 관리가 통째로 막히므로 time_rotating 으로 만료 전에 자동 교체한다.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

# 서울 리전 (기본 provider)
provider "aws" {
  region = var.region_seoul
}


# 도쿄 리전 (alias provider)
provider "aws" {
  alias  = "tokyo"
  region = var.region_tokyo
}


### 서울 인프라 ###
module "seoul" {
  source = "./modules/region_stack"

  region         = var.region_seoul
  vpc_cidr_block = var.vpc_cidr_seoul
  pjt_prefix     = "seoul"
  subnets        = var.subnets_seoul
}


### 도쿄 인프라 ###
module "tokyo" {
  source = "./modules/region_stack"
  providers = {
    aws = aws.tokyo
  }

  region         = var.region_tokyo
  vpc_cidr_block = var.vpc_cidr_tokyo
  pjt_prefix     = "tokyo"
  subnets        = var.subnets_tokyo
}
