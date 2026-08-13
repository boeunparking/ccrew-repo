variable "region" {
  type        = string
}
variable "vpc_id" {
  type = string
}

variable "pjt_name" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}
