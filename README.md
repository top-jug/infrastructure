# 탑저그 (TopJug) 🧗

> 여러 암장의 정보 및 이벤트를 한눈에 확인하고, 나만의 클라이밍 기록까지 관리하는 클라이밍 플랫폼

---

## 서비스 소개

클라이머라면 여러 암장을 다니면서 각 암장의 세팅 일정, 이벤트, 회원권 정보를 따로따로 확인해야 했습니다.  
**탑저그**는 이 모든 정보를 하나의 플랫폼에서 해결합니다.

- 📍 **주변 암장 탐색** — 위치 기반으로 근처 암장을 빠르게 찾기
- 📅 **세팅 일정 통합** — 여러 암장의 루트 세팅 일정을 한 화면에서 확인
- 🎫 **회원권 관리** — 보유한 회원권 만료일 및 잔여 횟수 한눈에 파악
- 📈 **클라이밍 기록** — 방문한 암장과 완등한 문제 난이도(V-scale) 기록
- 🔔 **알림** — 회원권 만료 임박, 잔여 횟수 1회, 장비 교체 필요 시 푸시 알림

---

## 기술 스택

| 영역 | 기술 | 선택 이유 |
|------|------|-----------|
| Cloud | AWS ap-northeast-2 (서울) | 팀 친숙도 + 국내 사용자 |
| IaC | Terraform >= 1.6 | 코드로 인프라 관리, 재현 가능 |
| Container | ECS EC2 Launch Type (t4g, ARM) | Fargate 대비 비용 절감 |
| Compute | t4g.small (2vCPU / 2GiB) | Graviton2 ARM — x86 대비 ~20% 저렴 |
| Database | RDS PostgreSQL 16 (db.t4g.micro) | PostGIS 위치 검색, 관계형 데이터 |
| Cache | Redis 7 (ECS Task) | ElastiCache 대비 비용 절감 |
| Service Discovery | AWS Cloud Map | API → Redis 내부 DNS (redis.topjug.local) |
| Secrets | AWS Secrets Manager | DB 비밀번호 안전 보관, 자동 교체 가능 |
| CDN | CloudFront + S3 | 정적 파일 배포 + /api/* ALB 라우팅 |
| Registry | ECR | AWS 네이티브 컨테이너 저장소 |
| Load Balancer | ALB (HTTP → HTTPS 리다이렉트) | 도메인 연결 후 자동 HTTPS 전환 |

---

## 아키텍처

```
[사용자 브라우저 / PWA]
         │
    [CloudFront]
    ├── S3 (프론트엔드 정적 파일)        ← 기본 경로 /
    └── ALB (API 요청 /api/*)           ← /api/* 경로
              │  HTTP(80) → HTTPS(443) 리다이렉트
    [ECS EC2 (t4g.small, ARM Graviton2)]
    ├── API 서버 Task (256 CPU / 512MB)
    │     └── redis.topjug.local:6379 (Cloud Map DNS)
    └── Redis Task (256MB)
              │
         [RDS PostgreSQL 16]
         (db.t4g.micro, VPC 내부 접근만 허용)

    [S3 Uploads]  ← 프로필 사진, 암장 이미지 (Presigned URL)
    [Secrets Manager]  ← DB 비밀번호 (ECS Task가 ARN으로 직접 참조)
```

### 네트워크 보안 구조

```
인터넷
  │
ALB SG (80, 443 인바운드 허용)
  │
ECS SG (ALB SG 소스 포트 3000만 허용 + self 참조로 Redis 통신)
  │
RDS SG (VPC CIDR 내부 5432만 허용)
```

- **NAT Gateway 없음** — Public Subnet + SG 인바운드 통제로 대체 (월 ~$32 절감)
- **ECS → ALB 전용 인바운드** — ECS Task는 ALB에서 오는 트래픽만 수신
- **Redis 통신** — ECS SG self 참조로 API ↔ Redis 내부 통신 허용

---

## 왜 이 아키텍처인가 (의사결정 기록)

팀 논의에서 아래와 같은 **멀티리전 고가용성 아키텍처**가 참고 자료로 제시되었습니다.

```
Route 53 → Region 1 / Region 2
  Transit Gateway Peering
  S3 CRR (Cross-Region Replication)
  ElastiCache Global Database
  Secrets Manager CCR
  DynamoDB
```

MVP 단계에서 이 구조를 그대로 채택하지 않은 이유는 다음과 같습니다.

| 항목 | 멀티리전 아키텍처 | 현재 선택 | 이유 |
|------|------------------|-----------|------|
| 리전 수 | 2개 | 1개 (서울) | 비용 2배, 초기 사용자 전부 국내 |
| Transit Gateway | 있음 | 없음 | 단일 리전에서 불필요, 월 ~$36 |
| S3 CRR | 있음 | 없음 | 단일 리전 S3로 충분 |
| ElastiCache | Global DB | ECS Redis Task | 월 ~$25 → 거의 $0 |
| Secrets Manager | 있음 | 동일하게 채택 | DB 비밀번호 안전 보관 |
| DynamoDB | 있음 | PostgreSQL | 이미 RDS 사용 중, 중복 불필요 |
| RDS Master/Slave | 있음 | Single (no replica) | MVP 단계 비용 최소화 |

**결론:** 현재 아키텍처는 초기 트래픽과 팀 규모에 맞게 비용을 최소화하면서도,  
트래픽 증가 시 수직·수평 확장이 가능하도록 설계되었습니다.

---

## 인프라 디렉토리 구조

```
topjug/
├── main.tf                    # Provider 및 모듈 호출
├── variables.tf               # 전역 변수 정의
├── outputs.tf                 # 주요 리소스 출력값
├── terraform.tfvars.example   # 환경변수 템플릿 (이걸 복사해서 tfvars 작성)
└── modules/
    ├── networking/            # VPC, 서브넷, IGW, Security Group (ALB/ECS/RDS)
    ├── ecr/                   # 컨테이너 이미지 저장소
    ├── loadbalancer/          # ALB, Target Group, HTTP/HTTPS 리스너
    ├── compute/               # ECS 클러스터, ASG, API/Redis 서비스, Cloud Map, Secrets Manager
    ├── database/              # RDS PostgreSQL
    ├── storage/               # S3 (프론트엔드 + 유저 업로드 + CORS)
    ├── cdn/                   # CloudFront 배포
    └── dns/                   # Route53 + ACM (도메인 준비 후 활성화)
```

---

## 시작하기

### 사전 요구사항

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6.0
- [AWS CLI](https://aws.amazon.com/ko/cli/) 설치 및 `aws configure` 완료
- IAM 유저 권한 (아래 관리형 정책 10개 + Secrets Manager 인라인 정책):

| 관리형 정책 |
|------------|
| AmazonEC2FullAccess |
| AmazonECS_FullAccess |
| AmazonEC2ContainerRegistryFullAccess |
| AmazonRDSFullAccess |
| AmazonS3FullAccess |
| AWSCloudMapFullAccess |
| CloudFrontFullAccess |
| ElasticLoadBalancingFullAccess |
| IAMFullAccess |
| CloudWatchLogsFullAccess |

> 인라인 정책 추가 필요: `secretsmanager:*` (관리형 정책 한도 10개 초과로 인라인으로 추가)

### 1. 환경변수 설정

```bash
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` 에서 `db_password` 값을 반드시 변경합니다.

> ⚠️ `terraform.tfvars` 는 `.gitignore` 에 포함되어 있습니다. 절대 커밋하지 마세요.

### 2. 배포

```bash
terraform init

# 네트워킹 먼저 (서브넷 count 의존성)
terraform apply -target=module.networking

# 전체 배포
terraform apply
```

### 3. 배포 완료 후 출력값

```bash
terraform output

# alb_dns_name      = "topjug-alb-xxxx.ap-northeast-2.elb.amazonaws.com"
# cloudfront_domain = "xxxx.cloudfront.net"
# ecr_api_url       = "xxxx.dkr.ecr.ap-northeast-2.amazonaws.com/topjug-api"
# uploads_bucket_name = "topjug-uploads-xxxx"
```

### 4. API 이미지 빌드 및 ECR 푸시

> ⚠️ t4g는 ARM(Graviton2) 아키텍처입니다. 이미지를 반드시 `linux/arm64` 로 빌드해야 합니다.

```bash
# ECR 로그인
aws ecr get-login-password --region ap-northeast-2 \
  | docker login --username AWS --password-stdin {ECR_URL}

# arm64 빌드
docker buildx build --platform linux/arm64 \
  -t {ECR_URL}/topjug-api:latest ./backend

docker push {ECR_URL}/topjug-api:latest

# ECS 서비스 재배포
aws ecs update-service \
  --cluster topjug-cluster \
  --service topjug-api \
  --force-new-deployment
```

### 5. DB 초기화 (첫 배포 시 1회)

```sql
-- RDS 접속 후 실행
CREATE EXTENSION IF NOT EXISTS postgis;
```

---

## 도메인 / HTTPS 연결 (선택 — 도메인 준비 후)

현재는 HTTP로 동작합니다. 도메인 준비가 되면 아래 순서로 HTTPS를 활성화합니다.

```
1. terraform.tfvars 에 domain_name = "topjug.kr" 추가
2. main.tf 에서 module "dns" 주석 해제
3. terraform apply → route53_nameservers 출력값 확인
4. 도메인 등록업체 네임서버에 4개 값 입력 (최대 48시간)
5. 인증서 검증 완료 후 main.tf loadbalancer 블록에 acm_certificate_arn 추가
6. terraform apply
```

---

## 이미지 업로드 흐름 (Presigned URL)

```
클라이언트                   API 서버                    S3
   │                           │                          │
   │── 업로드 URL 요청 ────────▶  │                          │
   │                           │── Presigned URL 생성 ───▶│
   │                           │◀── URL 반환 ─────────────│
   │◀── { uploadUrl, fileKey }─│                          │
   │                           │                          │
   │─── PUT {uploadUrl} (파일 직접 업로드) ───────────────▶ . 
   │                           │                          │
   │── 저장된 fileKey 전달 ────▶  │                          │
   │                           │── DB에 URL 저장          │
```

---

## 스케일업 가이드

`terraform.tfvars` 에서 아래 값 변경 후 `terraform apply`:

```hcl
# EC2 인스턴스 업그레이드 (더 많은 Task 수용)
ec2_instance_type = "t4g.medium"  # 4GiB

# API Task 수평확장
api_desired_count = 2

# RDS 수직확장
db_instance_class = "db.t4g.small"
```

