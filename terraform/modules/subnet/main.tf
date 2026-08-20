resource "aws_subnet" "tf_sn" {
  vpc_id            = var.vpc_id
  cidr_block        = var.cidr_block
  availability_zone = var.az_name

  tags = {
    Name = "${var.pjt_name}"
  }
}