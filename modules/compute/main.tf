# ── ECS 클러스터 ──────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${var.project}-cluster" }
}

# ── CloudWatch 로그 그룹 ───────────────────────────────────

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.project}/api"
  retention_in_days = 30
  # tags 제거 — logs:TagResource 권한 없으면 CreateLogGroup 자체가 실패함
}

resource "aws_cloudwatch_log_group" "redis" {
  name              = "/ecs/${var.project}/redis"
  retention_in_days = 14
}

# ── IAM: ECS Task Execution Role ─────────────────────────
# ECR pull, CloudWatch 로그 쓰기 권한

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── IAM: EC2 Instance Role ────────────────────────────────
# EC2가 ECS 클러스터에 등록되기 위한 권한 (Fargate엔 없던 것)

resource "aws_iam_role" "ecs_instance" {
  name = "${var.project}-ecs-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "${var.project}-ecs-instance-profile"
  role = aws_iam_role.ecs_instance.name
}

# ── ECS 최적화 AMI — arm64 (t4g 시리즈 전용) ─────────────
# t4g는 AWS Graviton2(ARM) 아키텍처이므로 arm64 ECS-optimized AMI 필요
# x86_64 경로: /amazon-linux-2/recommended/image_id

data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/arm64/recommended/image_id"
}

# ── Launch Template ───────────────────────────────────────

resource "aws_launch_template" "ecs" {
  name_prefix   = "${var.project}-ecs-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.ec2_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  network_interfaces {
    associate_public_ip_address = true # NAT GW 없이 ECR pull 필요
    security_groups             = [var.ecs_sg_id]
  }

  # EC2 부팅 시 ECS 클러스터에 자동 등록
  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo ECS_CLUSTER=${aws_ecs_cluster.main.name} >> /etc/ecs/ecs.config
    echo ECS_ENABLE_AWSLOGS_EXECUTIONROLE_OVERRIDE=true >> /etc/ecs/ecs.config
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.project}-ecs-instance" }
  }
}

# ── Auto Scaling Group ────────────────────────────────────

resource "aws_autoscaling_group" "ecs" {
  name                = "${var.project}-ecs-asg"
  vpc_zone_identifier = var.public_subnets
  min_size            = 1
  max_size            = 2 # 여유분 1대 (비용 최소화)
  desired_capacity    = 1

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-ecs-instance"
    propagate_at_launch = true
  }

  # 인스턴스 교체 시 새 인스턴스 먼저 올리고 기존 종료
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
    }
  }
}

# ── ECS Capacity Provider ─────────────────────────────────
# ASG와 ECS 클러스터를 연결

resource "aws_ecs_capacity_provider" "main" {
  name = "${var.project}-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs.arn

    managed_scaling {
      status          = "ENABLED"
      target_capacity = 80 # EC2 사용률 80% 기준으로 스케일링 판단
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.main.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
  }
}

# ── ECS Service Discovery (Cloud Map) ────────────────────
# API → Redis 내부 DNS 접근: redis.topjug.local:6379

resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "${var.project}.local"
  vpc  = var.vpc_id

  tags = { Name = "${var.project}-service-discovery" }
}

resource "aws_service_discovery_service" "redis" {
  name = "redis"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# ── Redis Task Definition ─────────────────────────────────

resource "aws_ecs_task_definition" "redis" {
  family                   = "${var.project}-redis"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "redis"
      image     = "redis:7-alpine"
      essential = true
      memory    = 256 # 컨테이너 레벨 메모리 제한

      portMappings = [{ containerPort = 6379, protocol = "tcp" }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.redis.name
          "awslogs-region"        = "ap-northeast-2"
          "awslogs-stream-prefix" = "redis"
        }
      }
    }
  ])

  tags = { Name = "${var.project}-redis-task" }
}

resource "aws_ecs_service" "redis" {
  name            = "${var.project}-redis"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.redis.arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
  }

  network_configuration {
    subnets         = [var.public_subnets[0]]
    security_groups = [var.ecs_sg_id]
    # assign_public_ip 제거 — EC2 인스턴스가 public IP 보유
  }

  service_registries {
    registry_arn = aws_service_discovery_service.redis.arn
  }

  depends_on = [aws_ecs_cluster_capacity_providers.main]

  tags = { Name = "${var.project}-redis-service" }
}

# ── API Task Definition ───────────────────────────────────

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project}-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = "${var.ecr_api_url}:latest"
      essential = true
      cpu       = var.api_cpu    # variables.tf 에서 주입 (기본값 256)
      memory    = var.api_memory # variables.tf 에서 주입 (기본값 512 MiB)

      portMappings = [{ containerPort = 3000, protocol = "tcp" }]

      environment = [
        { name = "NODE_ENV",   value = "production" },
        { name = "PORT",       value = "3000" },
        { name = "DB_HOST",    value = var.db_host },
        { name = "DB_PORT",    value = tostring(var.db_port) },
        { name = "DB_NAME",    value = var.db_name },
        { name = "DB_USER",    value = var.db_username },
        # REDIS_URL 형식으로 넘김 — 로컬 docker-compose와 동일한 환경변수 사용
        { name = "REDIS_URL",  value = "redis://redis.${var.project}.local:6379" },
      ]

      secrets = [
        # Secrets Manager ARN을 직접 참조 — SSM path 방식보다 권한 범위가 명확
        { name = "DB_PASSWORD", valueFrom = aws_secretsmanager_secret.db_password.arn }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = "ap-northeast-2"
          "awslogs-stream-prefix" = "api"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:3000/api/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = { Name = "${var.project}-api-task" }
}

resource "aws_ecs_service" "api" {
  name            = "${var.project}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_desired_count

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
  }

  network_configuration {
    subnets         = var.public_subnets
    security_groups = [var.ecs_sg_id]
  }

  load_balancer {
    target_group_arn = var.alb_target_group_arn
    container_name   = "api"
    container_port   = 3000
  }

  deployment_minimum_healthy_percent = 50  # EC2 1대 환경에서 100%면 배포 불가
  deployment_maximum_percent         = 200

  depends_on = [
    aws_ecs_service.redis,
    aws_ecs_cluster_capacity_providers.main
  ]

  tags = { Name = "${var.project}-api-service" }
}

# ── AWS Secrets Manager (DB 비밀번호) ────────────────────
# SSM SecureString 대비 장점:
#   - 자동 교체(rotation) 스케줄 설정 가능
#   - IAM 리소스 기반 정책으로 비밀별 세밀한 접근 제어
#   - ECS Task Definition에서 ARN으로 직접 참조

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project}/db_password"
  recovery_window_in_days = 0 # 즉시 삭제 — terraform destroy 후 재apply 시 충돌 방지

  tags = { Name = "${var.project}-db-password" }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}

resource "aws_iam_role_policy" "secrets_manager_read" {
  name = "${var.project}-secrets-manager-read"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      # 특정 secret ARN만 허용 — 와일드카드(*) 사용 금지
      Resource = aws_secretsmanager_secret.db_password.arn
    }]
  })
}

# ── IAM: API Task → S3 업로드 버킷 접근 ──────────────────
# Presigned URL 발급 및 파일 관리 권한

resource "aws_iam_role_policy" "s3_uploads" {
  name = "${var.project}-s3-uploads"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",    # Presigned URL 발급 (업로드)
        "s3:GetObject",    # 파일 조회
        "s3:DeleteObject", # 파일 삭제 (프로필 교체 시 기존 파일 정리)
      ]
      Resource = "${var.uploads_bucket_arn}/*"
    }]
  })
}
