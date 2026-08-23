# ccrew-tf 가 만든 네트워크 리소스 ID 출력
# 사용법: 이 디렉터리에서 `terraform output` 실행 후,
#         나온 값을 그대로 (다른 프로젝트의) terraform.tfvars 에 복사해서 사용
#         ccrew-tf 는 state 가 분리되어 있어 module.* 로 직접 참조가 안 되므로
#         이렇게 값을 뽑아서 넘겨줘야 함


### ---- 서울 (Active, 172.16.0.0/16) ---- ###

output "seoul_vpc_id" {
  description = "seoul-vpc"
  value       = module.seoul.vpc_id
}

output "seoul_db_subnet_ids" {
  description = "tf-seoul-db-sn5(172.16.4.0/24), tf-seoul-db-sn6(172.16.5.0/24)"
  value = [
    module.seoul.subnet_ids["db-sn5"],
    module.seoul.subnet_ids["db-sn6"],
  ]
}

output "seoul_private_subnet_ids" {
  description = "tf-seoul-pri-sn3(172.16.2.0/24), tf-seoul-pri-sn4(172.16.3.0/24)"
  value = [
    module.seoul.subnet_ids["pri-sn3"],
    module.seoul.subnet_ids["pri-sn4"],
  ]
}

output "seoul_ecs_sg_id" {
  description = "tf-seoul-ecs-sg"
  value       = module.seoul.ecs_sg_id
}

output "seoul_route_table_ids" {
  description = "tf-seoul-pri-rt34, tf-seoul-db-rt56"
  value = [
    module.seoul.route_table_ids["pri"],
    module.seoul.route_table_ids["db"],
  ]
}


### ---- 도쿄 (Warm Standby, 172.17.0.0/16) ---- ###

output "tokyo_vpc_id" {
  description = "tokyo-vpc"
  value       = module.tokyo.vpc_id
}

output "tokyo_db_subnet_ids" {
  description = "tf-tokyo-db-sn5(172.17.4.0/24), tf-tokyo-db-sn6(172.17.5.0/24)"
  value = [
    module.tokyo.subnet_ids["db-sn5"],
    module.tokyo.subnet_ids["db-sn6"],
  ]
}

output "tokyo_ecs_sg_id" {
  description = "tf-tokyo-ecs-sg"
  value       = module.tokyo.ecs_sg_id
}

# 크로스 리전 피어링(peering.tf)을 쓸 때만 필요
output "tokyo_route_table_ids" {
  description = "tf-tokyo-pri-rt34, tf-tokyo-db-rt56"
  value = [
    module.tokyo.route_table_ids["pri"],
    module.tokyo.route_table_ids["db"],
  ]
}


### ---- 컴퓨트 (서울) ---- ###

output "seoul_ecs_cluster_name" {
  value = aws_ecs_cluster.tf_cluster.name
}

output "seoul_ecs_service_name" {
  value = module.web_service.service_name
}

output "seoul_alb_arn_suffix" {
  value = module.alb.alb_arn_suffix
}


### ---- 컴퓨트 (도쿄) ---- ###

output "tokyo_ecs_cluster_name" {
  value = aws_ecs_cluster.tf_cluster_tokyo.name
}

output "tokyo_ecs_service_name" {
  value = module.web_service_tokyo.service_name
}

output "tokyo_alb_arn_suffix" {
  value = module.alb_tokyo.alb_arn_suffix
}


### ---- 백업/복원 대상 버킷 ---- ###
# destroy.yml 이 지우기 직전에, restore.yml 이 되돌릴 때 이 이름을 읽는다.
# 이름을 워크플로우에 박아두지 않는 이유는 뻔하다 — 여기서 바뀌면 저기도 바꿔야
# 한다는 걸 아무도 기억 못 하고, 그러면 "백업은 성공했는데 빈 버킷을 떴다"가 된다.

output "uploads_bucket_name" {
  description = "경매 업로드 이미지 버킷 (사용자가 올린 것 — 원본이 어디에도 없다)"
  value       = module.s3.source_bucket_name
}


### ---- Failover (Global Accelerator) ---- ###

output "api_fqdn" {
  description = "이 주소로 접속하면 Global Accelerator가 평상시 서울로 보내고, 서울 헬스체크 실패 시 (dial_percentage 조정을 통해) 도쿄로 전환할 수 있다"
  value       = aws_route53_record.api.name
}

output "accelerator_dns_name" {
  description = "Global Accelerator 자체의 anycast DNS 이름"
  value       = aws_globalaccelerator_accelerator.api.dns_name
}
