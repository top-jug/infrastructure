terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # 팀 공유 시 S3 backend로 교체 권장
  # backend "s3" {
  #   bucket = "topjug-tfstate"
  #   key    = "prod/terraform.tfstate"
  #   region = "ap-northeast-2"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "topjug"
      ManagedBy = "terraform"
    }
  }
}

# CloudFront ACM 인증서는 반드시 us-east-1 리전 필요
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "topjug"
      ManagedBy = "terraform"
    }
  }
}

# ── 모듈 호출 ────────────────────────────────────────────

module "networking" {
  source = "./modules/networking"

  project  = var.project
  vpc_cidr = var.vpc_cidr
  az_list  = var.az_list
}

module "ecr" {
  source = "./modules/ecr"

  project = var.project
}

module "loadbalancer" {
  source = "./modules/loadbalancer"

  project        = var.project
  vpc_id         = module.networking.vpc_id
  public_subnets = module.networking.public_subnet_ids
  alb_sg_id      = module.networking.alb_sg_id
  # 도메인 준비 완료 후: acm_certificate_arn = module.dns.acm_certificate_arn
}

# ── DNS / ACM (도메인 준비 후 주석 해제) ──────────────────
# 1. terraform.tfvars 에 domain_name 추가
# 2. 아래 블록 주석 해제 후 terraform apply
# 3. 출력된 route53_nameservers 를 도메인 등록업체에 등록
# 4. 인증서 검증 완료 후 loadbalancer 블록에 acm_certificate_arn 추가
#
# module "dns" {
#   source = "./modules/dns"
#
#   project      = var.project
#   domain_name  = var.domain_name
#   alb_dns_name = module.loadbalancer.alb_dns_name
#   alb_zone_id  = module.loadbalancer.alb_zone_id
# }

module "database" {
  source = "./modules/database"

  project        = var.project
  public_subnets = module.networking.public_subnet_ids
  rds_sg_id      = module.networking.rds_sg_id
  db_name        = var.db_name
  db_username    = var.db_username
  db_password    = var.db_password
  db_instance    = var.db_instance_class
}

module "compute" {
  source = "./modules/compute"

  project              = var.project
  vpc_id               = module.networking.vpc_id
  public_subnets       = module.networking.public_subnet_ids
  ecs_sg_id            = module.networking.ecs_sg_id
  alb_target_group_arn = module.loadbalancer.target_group_arn
  ecr_api_url          = module.ecr.api_repository_url
  db_host              = module.database.db_host
  db_port              = module.database.db_port
  db_name              = var.db_name
  db_username          = var.db_username
  db_password          = var.db_password
  api_cpu              = var.api_cpu
  api_memory           = var.api_memory
  api_desired_count    = var.api_desired_count
  ec2_instance_type    = var.ec2_instance_type
  uploads_bucket_arn   = module.storage.uploads_bucket_arn
}

module "storage" {
  source = "./modules/storage"

  project = var.project
}

module "cdn" {
  source = "./modules/cdn"

  providers = {
    aws = aws.us_east_1
  }

  project          = var.project
  s3_bucket_id     = module.storage.bucket_id
  s3_bucket_domain = module.storage.bucket_regional_domain
  alb_dns_name     = module.loadbalancer.alb_dns_name

  depends_on = [module.storage]
}

# ── S3 버킷 정책 (CloudFront OAC만 허용) ─────────────────
# cdn 모듈은 us-east-1 provider라 ap-northeast-2 버킷에 정책을 걸면
# 307 에러 발생 → default provider(ap-northeast-2)로 여기서 직접 적용

resource "aws_s3_bucket_policy" "frontend" {
  bucket = module.storage.bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "arn:aws:s3:::${module.storage.bucket_id}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = module.cdn.cloudfront_distribution_arn
        }
      }
    }]
  })

  depends_on = [module.storage, module.cdn]
}
