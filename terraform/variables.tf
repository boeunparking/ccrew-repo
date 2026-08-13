### 리전 ###
variable "region_seoul" {
  description = "서울 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "region_tokyo" {
  description = "도쿄 리전"
  type        = string
  default     = "ap-northeast-1"
}


### VPC CIDR ###
variable "vpc_cidr_seoul" {
  description = "서울 VPC CIDR"
  type        = string
  default     = "172.16.0.0/16"
}

variable "vpc_cidr_tokyo" {
  description = "도쿄 VPC CIDR"
  type        = string
  default     = "172.17.0.0/16"
}


### 서브넷 ###
variable "subnets_seoul" {
  description = "서울 리전 서브넷 정의 (CIDR, AZ, tier)"
  type = map(object({
    cidr = string
    az   = string
    tier = string
  }))
  default = {
    pub-sn1 = { cidr = "172.16.0.0/24", az = "ap-northeast-2a", tier = "public" },
    pub-sn2 = { cidr = "172.16.1.0/24", az = "ap-northeast-2c", tier = "public" },
    pri-sn3 = { cidr = "172.16.2.0/24", az = "ap-northeast-2a", tier = "ecs" },
    pri-sn4 = { cidr = "172.16.3.0/24", az = "ap-northeast-2c", tier = "ecs" },
    db-sn5  = { cidr = "172.16.4.0/24", az = "ap-northeast-2a", tier = "db" },
    db-sn6  = { cidr = "172.16.5.0/24", az = "ap-northeast-2c", tier = "db" }
  }
}

variable "subnets_tokyo" {
  description = "도쿄 리전 서브넷 정의 (CIDR, AZ, tier)"
  type = map(object({
    cidr = string
    az   = string
    tier = string
  }))
  default = {
    pub-sn1 = { cidr = "172.17.0.0/24", az = "ap-northeast-1a", tier = "public" },
    pub-sn2 = { cidr = "172.17.1.0/24", az = "ap-northeast-1c", tier = "public" },
    pri-sn3 = { cidr = "172.17.2.0/24", az = "ap-northeast-1a", tier = "ecs" },
    pri-sn4 = { cidr = "172.17.3.0/24", az = "ap-northeast-1c", tier = "ecs" },
    db-sn5  = { cidr = "172.17.4.0/24", az = "ap-northeast-1a", tier = "db" },
    db-sn6  = { cidr = "172.17.5.0/24", az = "ap-northeast-1c", tier = "db" }
  }
}
