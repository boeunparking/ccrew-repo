# 라우팅 테이블
resource "aws_network_acl" "tf_nacl" {
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.pjt_name}"
  }
}