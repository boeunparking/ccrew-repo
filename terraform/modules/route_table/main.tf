# 라우팅 테이블
resource "aws_route_table" "tf_rt"{
  vpc_id = var.vpc_id

  tags = {
    Name = "${var.pjt_name}"
  }
}