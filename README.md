# cloud-duck

서울(Active) + 도쿄(Warm Standby/DR) 2리전 구성의 경매 서비스.
인프라(Terraform)와 애플리케이션(Node.js)이 한 저장소에 있다.

## 저장소 구조

```
ccrew-repo/
├── terraform-bootstrap/   # state 버킷 + GitHub OIDC/CI 롤 (사람이 직접만 apply)
├── terraform/             # 실제 인프라 전부 (VPC ~ ECS ~ RDS ~ VPN)
├── web/                   # API 서버 (ECS Fargate, ALB 뒤)
├── batch/                 # 백그라운드 워커 (Fargate Spot, ALB 없음)
├── ccrew-frontend/        # 프론트엔드 (React + vite, S3 + CloudFront 정적 배포)
├── db/schema.sql          # RDS 테이블 스키마
└── .github/workflows/     # 전체 배포 파이프라인 (ECR → 이미지 → 인프라 → 프론트)
```

`terraform-bootstrap`과 `terraform`은 **state가 분리되어 있다.** bootstrap은 CI의 신원(IAM 롤)과
state 저장소 자체를 만드는데, 그걸 메인 스택에 두면 메인을 destroy할 때 CI 복구 수단까지
같이 사라지기 때문이다(실제로 겪었음).

## 네트워크 구성

| | 서울 (`module.seoul`) | 도쿄 (`module.tokyo`) |
|---|---|---|
| 리전 | ap-northeast-2 | ap-northeast-1 |
| VPC CIDR | 172.16.0.0/16 | 172.17.0.0/16 |
| public | pub-sn1/2 (172.16.0~1.0/24) | pub-sn1/2 (172.17.0~1.0/24) |
| ecs | pri-sn3/4 (172.16.2~3.0/24) | pri-sn3/4 (172.17.2~3.0/24) |
| db | db-sn5/6 (172.16.4~5.0/24) | db-sn5/6 (172.17.4~5.0/24) |

온프레미스(모의) VPC는 `10.0.0.0/16`, Client VPN 클라이언트 대역은 `10.200.0.0/22`로
서로 겹치지 않게 잡혀 있다.

두 리전은 `region_stack` 모듈 **하나를 두 번 호출**해서 만든다(`terraform/main.tf`).
보안그룹·NACL의 실제 **규칙**은 모듈 안이 아니라 `modules/region_stack/main.tf`에 있다 —
`modules/security_group/`을 열면 껍데기만 있어서 헷갈리기 쉽다.

## 애플리케이션

| | web | batch |
|---|---|---|
| 역할 | 사용자 API (로그인·경매·입찰) | 백그라운드 워커 |
| 트리거 | ALB로 들어오는 HTTP 요청 | 30초 주기 폴링 (요청 없음) |
| 하는 일 | REST API + WebSocket | 마감 경매 낙찰 메일(SES), 인기상품 통계 |
| 데이터 | RDS + Valkey | Valkey만 |
| 실행 | FARGATE | FARGATE_SPOT |

동시 입찰은 Valkey Lua 스크립트(`web/src/lua/bid.lua`)로 원자적으로 처리한다.
프로세스 내 락은 ECS 태스크가 2개 이상이면 무의미하므로, 모든 태스크가 공유하는
Valkey에서 "조회+검증+갱신"을 한 번에 끝낸다.

## 배포

인프라 생성부터 이미지 배포까지 전 과정이 GitHub Actions에서 돈다.
사람이 직접 하는 건 아래 "최초 1회"뿐이다.

### 최초 1회 (사람이 직접)

bootstrap만은 CI가 만들 수 없다 — Actions가 AWS에 로그인하는 수단(OIDC 롤)과
`terraform init`이 붙을 backend(state 버킷)를 만드는 게 바로 이 스택이기 때문이다.
자기를 만들어 줄 권한을 자기가 만들 수는 없다.

```bash
cd terraform-bootstrap
terraform init && terraform apply     # state 버킷 + CI 롤 2개
```

그다음 저장소에 Secrets를 등록한다 (Settings > Secrets and variables > Actions).

| 이름 | 비고 |
|---|---|
| `AWS_ACCOUNT_ID` | OIDC 롤 ARN을 조립하는 데 쓴다 |
| `GOOGLE_CLIENT_SECRET` | 구글 로그인용(Cognito Identity Provider). 없으면 apply가 변수 validation에서 멈춘다 |

카카오는 지원하지 않는다 — 회원/소셜 로그인이 Cognito User Pool로 넘어갔는데
Cognito가 기본 지원하는 IdP가 아니라 뺐다. 예전에 등록해 둔
`KAKAO_CLIENT_SECRET` / `KAKAO_REST_API_KEY` 는 이제 아무 데서도 참조하지 않으므로
지워도 된다.

**등록할 게 이 둘뿐인 이유**는 나머지가 이미 저장소에 있기 때문이다.
인증서 ARN·알람 이메일·구글 client_id 같은 값은 `terraform/terraform.tfvars`에 들어
있고 그 파일은 git에 추적되고 있다(`.gitignore`에 `*.tfvars`가 있지만, 그 규칙이
추가되기 전부터 추적 중이라 계속 따라간다 — gitignore는 이미 추적 중인 파일에는
적용되지 않는다). 즉 CI 체크아웃에도 그대로 있으므로 따로 넘길 필요가 없다.

반면 `client_secret` 은 `secrets.auto.tfvars`에 있고 그 파일은 추적되지 않는다.
CI에는 존재하지 않으므로 이 값만 Secrets에서 가져온다.

구글 클라우드 콘솔의 "승인된 리디렉션 URI"에는 우리 백엔드 주소가 아니라 Cognito가
관리하는 고정 URI를 등록한다. apply 후 아래로 확인한다:

```bash
terraform -chdir=terraform output cognito_google_idp_response_uri
```

로컬에서 apply하려면 `secrets.auto.tfvars`만 채우면 된다
(`cp secrets.auto.tfvars.example secrets.auto.tfvars`).

### 이후 전 과정 (자동)

`main`에 `web/**`, `batch/**`, `terraform/**` 변경이 push되면
`.github/workflows/deploy.yml`이 네 단계로 돈다.

| 잡 | 하는 일 | 롤 |
|---|---|---|
| `preflight` | 위 Secrets가 비어 있는지 먼저 검사 | — |
| `ecr` | ECR 저장소 + 도쿄 복제 설정만 `-target`으로 생성 | `github-actions-terraform` |
| `image` | web/batch 이미지 빌드 → 커밋 SHA 태그로 푸시 | `github-actions-ecr-push` |
| `infra` | 전체 `terraform apply` (ECS 재배포 포함) | `github-actions-terraform` |
| `frontend` | `ccrew-frontend` 체크아웃 → vite 빌드 → S3 업로드 → CloudFront 무효화 | `github-actions-frontend-deploy` |

**이 한 번으로 인프라·백엔드·프론트엔드가 전부 선다.** 프론트 소스는 별도 저장소지만
`frontend` 잡이 그 저장소를 체크아웃해서 빌드하므로, 사람이 따로 돌릴 일이 없다.
`infra` 뒤에 있는 이유는 올릴 버킷과 무효화할 배포가 거기서 만들어지기 때문이다.

**ECR을 따로 먼저 만드는 이유**는 닭-달걀 때문이다. ECR이 없으면 push할 수 없고,
이미지가 없는 상태로 전체 apply를 하면 ECS는 "성공"하지만(ECS는 이미지 존재를
검증하지 않는다) 태스크가 `CannotPullContainerError`로 계속 죽는다.
ECR만 먼저 만들고 → 푸시 → 전체 apply하면 그 창이 아예 없다.

복제 설정을 `ecr` 잡에 같이 넣은 것도 같은 이유다. `aws_ecr_replication_configuration`은
"설정된 뒤에 푸시된" 이미지부터 복제하므로, 푸시 후에 켜면 첫 이미지가 도쿄로 안 넘어간다.

**`preflight`가 있는 이유**: Secrets가 없어도 `${{ secrets.X }}`는 에러가 아니라 빈
문자열이 된다. `AWS_ACCOUNT_ID`가 비면 롤 ARN이 `arn:aws:iam:::role/...`로 조립돼
"왜 OIDC가 안 되지"를 한참 찾게 되고, `GOOGLE_CLIENT_SECRET`이 비면 20분 걸리는
전체 apply를 끝까지 돌린 뒤에야 변수 validation에서 죽는다. 둘 다 30초에 앞당겨 잡는다.

**이미지 태그는 `-var`로 넘긴다** (`TF_VAR_` 환경변수가 아니라). terraform의 변수
우선순위는 낮은 쪽부터 `TF_VAR_ 환경변수 < terraform.tfvars < *.auto.tfvars < -var`
순인데, `TF_VAR_`가 제일 약해서 `terraform.tfvars`에 같은 변수가 있으면 그냥 무시된다.
"태그를 넘겼는데 옛 이미지가 배포되는" 형태로 조용히 어긋나므로 가장 강한 `-var`를 쓴다.

**인프라도 CI가 apply한다.** 그래서 콘솔에서 손으로 바꾼 설정은 다음 배포 때
코드 상태로 되돌아간다. 그게 이 방식의 목적이자 대가이므로, 임시 변경도 코드에 반영할 것.

계획만 보고 싶으면 Actions 탭 > `Run workflow` > `mode: plan`. 아무것도 바꾸지 않고
`terraform plan` 결과만 출력한다.

### IAM 롤이 두 개인 이유

| 롤 | 권한 | 쓰는 잡 |
|---|---|---|
| `github-actions-ecr-push` | ReadOnly + ECR 푸시 + ECS 태스크 정의 갱신 | `image` |
| `github-actions-terraform` | AdministratorAccess | `ecr`, `infra` |

전체 apply는 VPC/RDS/IAM/KMS/Secrets Manager/CloudFront/Route53/Lambda/VPN을 전부
생성·삭제해야 해서 사실상 계정 전권이 필요하다. 그 전권을 기존의 좁은 롤에 얹으면
좁혀둔 의미가 통째로 사라지므로 "큰 망치"만 별도 롤로 분리했다. 워크플로우의
`role-to-assume` ARN만 보고 그 잡이 어느 권한으로 도는지 구분된다는 이점도 있다.

최소권한 정책을 직접 쓰지 않은 이유는, 리소스가 늘 때마다 Action을 추가하지 않으면
apply가 중간에 `AccessDenied`로 멈추기 때문이다. terraform은 부분 실패해도 이미 만든
리소스가 state에 남으므로, 권한 누락은 "실패"가 아니라 "반쯤 배포된 상태"를 만든다.

둘 다 신뢰 정책이 **ccrew-repo의 main 브랜치**로 한정돼 있다(fork PR·다른 브랜치는
assume 불가). 바꿔 말하면 main에 푸시할 수 있는 사람이 계정 관리자와 같은 힘을
갖는다는 뜻이므로, **main 브랜치 보호 규칙(리뷰 필수)을 함께 켜 두는 걸 권한다.**

### 이미지 태그는 어디에도 적어두지 않는다

`image_tag_web`/`image_tag_batch`를 안 넘기면 terraform이 ECR에서 **마지막으로 푸시된
이미지**를 찾아 쓴다(`compute.tf`의 `data.aws_ecr_image`). 그래서 로컬에서 그냥
`terraform apply`만 해도 지금 떠 있는 것과 같은 이미지가 유지된다.

예전에는 `terraform.tfvars`에 커밋 SHA를 적어 두고, CI의 `sync-image-tag` 잡이 배포
성공 후 그 두 줄을 다시 커밋해서 맞췄다. 그 잡이 성공해야만 파일과 실제가 일치했고,
사람이 그 사이에 로컬 apply를 하면 방금 배포한 이미지가 조용히 롤백됐다.
적어두지 않으면 어긋날 것도 없어서 그 잡을 통째로 없앴다.

CI는 지금도 커밋 SHA를 `-var`로 명시해 넘긴다 — "이 커밋이 이 이미지"라는 보장은
CI 쪽에 있어야 하고, 자동 조회는 값을 모르는 로컬 apply를 위한 안전망이다.

특정 버전으로 되돌릴 때만 명시한다:

```powershell
terraform apply -var image_tag_web=<커밋SHA> -var image_tag_batch=<커밋SHA>
```

## 프론트엔드 배포

프론트엔드 소스는 `ccrew-frontend/`에 있다 — `web`(API)·`batch`(워커)와 같은
저장소다. 위 파이프라인의 `frontend` 잡이 **vite 빌드 → S3 업로드 → CloudFront
무효화**까지 처리하므로 따로 돌릴 것이 없다.

원래는 `boeunparking/ccrew-frontend`라는 별도 저장소였다. 한 저장소로 합친 이유는
네 잡이 **항상 같은 커밋을 빌드**하게 만들기 위해서다 — 나뉘어 있으면 "인프라는 새
버전인데 프론트는 옛 버전" 같은 어긋남이 생기고, 어느 프론트 커밋이 올라갔는지
되짚으려면 두 저장소의 이력을 대조해야 한다. 체크아웃 토큰(PAT)이 필요 없어지는 것도 덤이다.

배포 대상(버킷 이름 / CloudFront 배포 ID)은 GitHub Secrets에 복사해 두지 않고
**SSM Parameter Store**에서 읽는다. 그 값은 이 저장소의 terraform이 인프라를
만들면서 같이 써 둔다(`terraform/cloudfront.tf`).

| SSM 경로 | 값 |
|---|---|
| `/cloud-duck/frontend/bucket_name` | 정적 파일 S3 버킷 |
| `/cloud-duck/frontend/distribution_id` | CloudFront 배포 ID |

**왜 SSM인가**: CloudFront 배포 ID는 우리가 정하는 이름이 아니라 AWS가 생성 시점에
부여하는 값이라, destroy 후 재구축하면 바뀐다. Secrets에 복사해 둔 값은 그대로
남으므로 무효화가 이미 없어진 배포로 날아가고, 프론트 배포는 초록불인데 사용자에게는
옛 화면이 계속 보인다. 사람이 옮겨 적는 단계를 없애면 어긋날 수가 없다.
두 저장소가 state를 공유하지 않으므로 remote state 대신 SSM을 경유한다.

업로드는 캐시 수명이 정반대라 두 번에 나눈다:

| 대상 | Cache-Control | 이유 |
|---|---|---|
| `assets/*` | `max-age=31536000, immutable` | vite가 파일명에 콘텐츠 해시를 박아서 내용이 바뀌면 이름이 바뀐다 |
| 나머지 | `no-cache` | `index.html`·`config.js`는 이름이 고정. 캐시되면 새 번들을 가리키는 파일이 안 내려간다 |

자산을 먼저 올리는 순서도 의도적이다 — `index.html`이 내려간 순간 그게 가리키는
파일이 이미 S3에 있어야 한다. 마지막으로 무효화가 **완료될 때까지 기다린다**
(`aws cloudfront wait invalidation-completed`). 안 기다리면 잡이 초록불인 시점에도
사용자는 여전히 옛 파일을 받는다.

프론트 배포에 추가로 등록할 Secret은 없다. 위 "최초 1회"의 셋이 전부다.

옛 `boeunparking/ccrew-frontend` 저장소는 **IAM 신뢰 정책에서 빼두었다**
(`sub_frontend_deploy`). 소스가 두 곳에 남아 있는 동안 그쪽에 누가 푸시하면 옛 코드가
같은 S3 버킷을 덮어써서 방금 배포한 화면이 조용히 되돌아가기 때문이다. 지금은 그
워크플로우가 AssumeRole 단계에서 시끄럽게 실패하므로 착각할 여지가 없다.
정리가 끝나면 그 저장소는 archive 하는 게 좋다.

### 버킷은 인프라와 함께 만들어지고 함께 사라진다

프론트엔드 버킷은 다른 앱 버킷과 마찬가지로 `apply`로 만들어지고 `destroy`로
사라진다(`force_destroy = true`라 버저닝된 이전 버전과 삭제 마커까지 전부 지운다).
잃어도 되는 데이터라 이렇게 뒀다 — 내용물은 빌드 산출물이고 원본은 git에 있다.

재구축하면 버킷이 빈 상태로 만들어지지만, 같은 파이프라인의 `frontend` 잡이
바로 뒤이어 채우므로 사람이 손댈 일은 없다.

**이전 버전은 7일 뒤 자동 삭제된다** (`aws_s3_bucket_lifecycle_configuration`).
버저닝이 켜져 있는데 배포가 매번 `sync --delete`라, 안 치우면 push 횟수만큼
이전 버전과 삭제 마커가 무한히 쌓인다. 비용도 문제지만 `force_destroy`가
destroy 때 그 버전을 1000개씩 나눠 지워야 해서 재구축이 갈수록 느려진다.
7일이면 잘못된 배포를 알아채고 되돌리기에 충분하고, 그 이상 둘 이유가 없다.

## 삭제와 복원

Actions 탭에서 수동 실행하는 워크플로우가 둘 있다. 둘 다 `push` 트리거가 없다.

| 워크플로우 | 입력 | 하는 일 |
|---|---|---|
| `Destroy (전체 인프라 삭제)` | `confirm: destroy` | 데이터 백업 → `terraform destroy` |
| `Restore (백업 복원)` | `target`, `confirm: restore`, `stamp`(선택) | 백업본을 지금 버킷으로 되돌림 |

### destroy가 데이터를 먼저 대피시킨다

지우기 전에 업로드 이미지와 프론트 정적 파일을 bootstrap의 백업 버킷
(`cloud-duck-backup-<계정ID>`)으로 `sync`한다. 그 버킷은 **별도 스택이라 destroy로
사라지지 않고** `prevent_destroy`도 걸려 있다.

**왜 "버킷을 살려두기"가 아니라 "복사본을 남기기"인가.** 업로드 버킷은 메인 스택의
고객관리형 KMS 키(`aws_kms_key.seoul`)로 암호화돼 있다. 버킷만 destroy 대상에서 빼도
그 키는 삭제 예약(7일)에 들어가고, **키가 사라지는 순간 버킷은 멀쩡한데 안의 객체가
전부 영구 복호화 불가**가 된다. `sync`로 복사하면 목적지 버킷의 키(AES256)로 다시
암호화되므로 원본 키의 운명과 무관해진다. 복사본 쪽이 실제로 더 안전하다.

백업은 **타임스탬프 폴더에 새로 쌓는다**(덮어쓰지 않는다). 고정 경로에 `--delete`로
sync하면 실수로 destroy를 두 번 돌렸을 때, 두 번째 실행이 이미 비어 있는 원본을
백업하면서 멀쩡한 첫 백업을 통째로 지운다. 되돌릴 방법이 없는 사고라 경로를 나눴다.
90일 지난 백업은 lifecycle 규칙이 정리한다.

### 재구축 순서

```
Destroy → Deploy(재구축) → Restore (target: uploads)
```

프론트는 `Restore` 없이도 `Deploy`의 `frontend` 잡이 소스에서 다시 빌드해 채운다.
**`Restore`가 꼭 필요한 건 업로드 이미지**다 — 사용자가 올린 것이라 원본이 없다.
프론트 빌드가 깨져 직전 배포본을 그대로 되올리고 싶을 때만 `target: frontend`를 쓴다.

`Restore`는 자동이 아니라 수동이다. 살아 있는 버킷에 옛 파일을 덮어쓰는 작업이라
배포마다 자동으로 돌면 "왜 지운 이미지가 되살아나지"가 된다. `--delete`도 쓰지 않아
백업 이후에 새로 올라온 파일은 건드리지 않는다.

### destroy가 못 지우는 것 / 오래 걸리는 것

- **`terraform-bootstrap`은 안 지워진다** — state 버킷·OIDC 롤·백업 버킷. 이게 사라지면
  재구축 수단 자체가 없어진다(의도된 동작).
- **`timeout-minutes: 120`** — CloudFront 배포 삭제만 15~20분(비활성화 후 삭제),
  Global Accelerator·Client VPN·RDS도 각각 몇 분씩 걸린다.
- destroy도 plan을 거치므로 `-var`로 이미지 태그를 넘긴다. 안 넘기면
  `data.aws_ecr_image`가 켜져서 빈 ECR을 조회하다 **시작도 못 한다.**

## 주의사항

- **로컬 apply와 CI가 동시에 돌면** 뒤에 온 쪽이 state 락에 막혀 실패한다(정상 동작).
  락은 실행 중인 프로세스가 살아있는 한 **절대 강제 해제하면 안 된다** — state가 깨진다.
  CI 실행끼리는 워크플로우의 `concurrency` 그룹이 줄을 세우므로 서로 충돌하지 않는다.
  `cancel-in-progress`는 일부러 꺼 두었다 — apply 도중 취소하면 state와 실제 인프라가
  어긋난 채로 남기 때문이다.
- **Client VPN 인증서**: 서버 인증서는 도메인이 있어야 하고, 클라이언트 루트 인증서는
  easy-rsa로 만든 **CA 인증서**여야 한다. 서버 인증서를 양쪽에 재사용하면 상호 인증이 안 된다.
- **S3 버킷 이름은 전역 고유**해야 한다. state 버킷은 계정 ID를 이름에 넣어 충돌을 막지만,
  앱 버킷(`cloud-duck-source-apne2` 등)은 아직 그렇지 않다.
- **Valkey는 TLS 필수**(`transit_encryption_enabled = true`). 앱은 `rediss://`로 접속해야 한다.
- **도쿄 RDS는 읽기 전용** 크로스 리전 replica다. 도쿄로 쓰기 요청이 가면 실패하므로,
  Global Accelerator의 도쿄 `traffic_dial_percentage`는 0으로 막아 두었다.
  실제 페일오버는 dial을 올리는 것만으로 끝나지 않고 **RDS promote가 함께 필요**하다(미자동화).
- **Secrets Manager 7일 복구 대기는 해결돼 있다.** 4개 시크릿 전부
  `recovery_window_in_days = 0`이라 destroy 즉시 사라지고, 재구축 때 같은 이름을 바로 쓴다.
  (예전엔 손으로 `--force-delete-without-recovery`를 돌려야 했다.)
- **RDS는 최종 스냅샷을 남기지 않는다** (`skip_final_snapshot = true`). 남기면 destroy는
  성공인데 스냅샷만 남아 계속 과금되고, 고정 이름을 쓰면 다음 destroy가
  `DBSnapshotAlreadyExists`로 막힌다. 대신 **destroy하면 DB 내용은 사라진다** —
  스키마는 앱이 부팅할 때 다시 만들지만(`web/src/schema.js`) 데이터는 안 돌아온다.
- **ECR이 완전히 비어 있으면** 로컬 `terraform apply`가 이미지 조회 단계에서 멈춘다
  (`data.aws_ecr_image`가 찾을 게 없다). 파이프라인은 `ecr` → `image` → `infra`
  순서라 그 상황을 만들지 않지만, 최초 구축을 로컬에서 하려면 태그를 직접 넘겨야 한다:
  `terraform apply -var image_tag_web=x -var image_tag_batch=x`. 그러면 ECS는 뜨지만
  이미지가 없어 태스크가 재시작을 반복하므로, 이미지를 올린 뒤 다시 apply해야 한다.
  **그냥 파이프라인을 돌리는 게 맞다.**
- **RDS Multi-AZ와 AZ 고정은 함께 쓸 수 없다.** `multi_az = true`면 `availability_zone`을
  지정하면 안 된다(모듈에서 조건부로 처리해 둠).
