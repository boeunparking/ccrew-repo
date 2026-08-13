output "vpc_id" {
  value = module.vpc.vpc_id
}

output "igw_id" {
  value = module.vpc.igw_id
}

output "subnet_ids" {
  value = { for k, v in module.subnet : k => v.sn_id }
}

output "alb_sg_id" {
  value = module.alb_sg.sg_id
}

output "ecs_sg_id" {
  value = module.ecs_sg.sg_id
}

output "db_sg_id" {
  value = module.db_sg.sg_id
}

output "route_table_ids" {
  value = {
    pub = module.pub_rt.rt_id
    pri = module.pri_rt.rt_id
    db  = module.db_rt.rt_id
  }
}

output "alb_nacl_id" {
  value = module.alb_nacl.nacl_id
}

output "ecs_nacl_id" {
  value = module.ecs_nacl.nacl_id
}

output "db_nacl_id" {
  value = module.db_nacl.nacl_id
}

# db-sn5 + db-sn6 을 합친 /23 대역 (피어링 라우팅/보안 규칙에서 사용)
output "db_cidr_23" {
  value = local.db_cidr_23
}

output "vpc_cidr_block" {
  value = var.vpc_cidr_block
}
