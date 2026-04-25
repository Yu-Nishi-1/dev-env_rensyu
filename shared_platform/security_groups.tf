resource "aws_security_group" "allow_alb" {
  name        = "allow_alb"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "allow_443" {
  security_group_id = aws_security_group.allow_alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  ip_protocol       = "tcp"
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "allow_80" {
  security_group_id = aws_security_group.allow_alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.allow_alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}

###########################

resource "aws_security_group" "allow_legacy_app" {
  name        = "allow_legacy_app"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "allow_app_80" {
  security_group_id = aws_security_group.allow_legacy_app.id
  referenced_security_group_id = aws_security_group.allow_alb.id
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_app_ipv4" {
  security_group_id = aws_security_group.allow_legacy_app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}

###########################

resource "aws_security_group" "allow_legacy_rds" {
  name        = "allow_legacy_rds"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "allow_rds_3306" {
  security_group_id = aws_security_group.allow_legacy_rds.id
  referenced_security_group_id = aws_security_group.allow_legacy_app.id
  from_port         = 3306
  ip_protocol       = "tcp"
  to_port           = 3306
}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_rds_ipv4" {
  security_group_id = aws_security_group.allow_legacy_rds.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}