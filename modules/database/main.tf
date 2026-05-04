# ── RDS Subnet Group ─────────────────────────────────────
# RDS도 public subnet에 배치하되 SG로 VPC 내부만 허용

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = var.public_subnets

  tags = { Name = "${var.project}-db-subnet-group" }
}

# ── RDS PostgreSQL ────────────────────────────────────────

resource "aws_db_instance" "main" {
  identifier = "${var.project}-postgres"

  engine         = "postgres"
  engine_version = "16"  # 마이너 버전은 AWS가 최신으로 자동 선택
  instance_class = var.db_instance # 수직확장 시 이 값만 변경

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  allocated_storage     = 20  # 초기 20GB
  max_allocated_storage = 100 # 자동 스토리지 확장 (최대 100GB)
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]
  publicly_accessible    = false # VPC 내부에서만 접근

  backup_retention_period = 7   # 7일 자동 백업
  backup_window           = "03:00-04:00" # 새벽 3시 (트래픽 적은 시간)
  maintenance_window      = "sun:04:00-sun:05:00"

  # 개발 환경 — destroy 시 스냅샷 없이 즉시 삭제
  # 운영 전환 시: skip_final_snapshot = false 로 변경 후 final_snapshot_identifier 추가
  skip_final_snapshot = true

  deletion_protection = false # 개발 단계에서는 비활성화, 운영 시 true로 변경

  # 성능 인사이트 — db.t4g.micro/small 미지원, medium 이상에서만 활성화
  performance_insights_enabled = false

  tags = { Name = "${var.project}-postgres" }
}
