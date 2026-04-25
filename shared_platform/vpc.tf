resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_subnet" "pub_1a" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.101.0/24"
  availability_zone = "ap-northeast-1a"
  tags = {
    Type = "Public"
  }
}

resource "aws_subnet" "pub_1c" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.102.0/24"
  availability_zone = "ap-northeast-1c"
  tags = {
    Type = "Public"
  }
}

resource "aws_subnet" "pri_1a" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "ap-northeast-1a"
  tags = {
    Type = "Private"
  }
}

resource "aws_subnet" "pri_1c" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.2.0/24"
  availability_zone = "ap-northeast-1c"
  tags = {
    Type = "Private"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "shared_route" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "public" {
  destination_cidr_block = "0.0.0.0/0"
  route_table_id = aws_route_table.shared_route.id
  gateway_id = aws_internet_gateway.gw.id
}

resource "aws_route_table_association" "pub_1a" {
  subnet_id      = aws_subnet.pub_1a.id
  route_table_id = aws_route_table.shared_route.id
}

resource "aws_route_table_association" "pub_1c" {
  subnet_id      = aws_subnet.pub_1c.id
  route_table_id = aws_route_table.shared_route.id
}

resource "aws_route_table" "shared_route_private" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table_association" "pri_1a" {
  subnet_id      = aws_subnet.pri_1a.id
  route_table_id = aws_route_table.shared_route_private.id
}

resource "aws_route_table_association" "pri_1c" {
  subnet_id      = aws_subnet.pri_1c.id
  route_table_id = aws_route_table.shared_route_private.id
}
