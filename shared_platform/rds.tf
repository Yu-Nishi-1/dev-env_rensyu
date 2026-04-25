resource "aws_db_instance" "default" {
  allocated_storage    = 20
  db_name              = "app_db"
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t3.micro"
  username             = "appuser"
  password             = var.rds_password
  parameter_group_name = aws_db_parameter_group.legacy_pg.name
  db_subnet_group_name = aws_db_subnet_group.legacy_rds_subnet_group.name
  skip_final_snapshot  = true
  deletion_protection  = false
}

resource "aws_db_parameter_group" "legacy_pg" {
  name   = "legacy-pg"
  family = "mysql8.0"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "character_set_client"
    value = "utf8mb4"
  }
}

resource "aws_db_subnet_group" "legacy_rds_subnet_group" {
  name       = "legacy_rds_subnet_group"
  subnet_ids = [aws_subnet.pri_1a.id, aws_subnet.pri_1c.id]

  tags = {
    Name = "App DB subnet group"
  }
}