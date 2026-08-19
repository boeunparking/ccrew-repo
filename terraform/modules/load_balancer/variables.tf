variable "vpc_id" {
  type = string
}
variable "security_group_id" {
  type = string
}
variable "subnet_ids" {
  type = list(any)
}
variable "certificate_arn" {
  type = string
}
