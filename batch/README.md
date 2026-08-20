# clduck-worker

CloudDuck 백그라운드 워커. HTTP 서버가 아니라 `worker.js`가 상시 폴링 루프로 돈다.
`web/`과 완전히 같은 API 서버였던 예전 코드는 실제로 아무 것도 소비하지 않는 죽은 배포였어서
전부 걷어내고 이걸로 교체했다.

## 하는 일

1. **낙찰 알림** — `POLL_INTERVAL_SECONDS`마다 Valkey의 `auctions:open` 소트셋에서 마감시간이
   지난 경매를 찾아, 그 경매의 최고 입찰자(`auction:{id}:leader` 해시)에게 SES로 낙찰 메일을 보낸다.
2. **인기 상품 통계** — 같은 주기로 `auction:popularity` 소트셋(입찰마다 web이 `ZINCRBY`)에서
   상위 10개를 뽑아 `stats:popular:snapshot` 키에 JSON으로 캐싱한다.
   `GET /admin/stats/popular`(web의 admin 라우터)이 이 값을 그대로 읽어서 응답한다.

## 왜 워커가 여러 대 떠도 안전한가

`desired_count`가 1보다 커도(Fargate Spot 회수 대비 이중화) 낙찰 메일이 중복 발송되지 않는다.
`auctions:open`에서 후보를 꺼낸 뒤 `ZREM`으로 "이 경매를 내가 처리한다"는 걸 원자적으로
클레임하기 때문에, 여러 워커가 동시에 같은 경매를 집어도 `ZREM`이 1을 돌려주는 쪽만 실제로
처리하고 나머지는 건너뛴다.

## 필요한 상태 (web이 채워줌)

| 키 | 타입 | 채우는 곳 |
| --- | --- | --- |
| `auctions:open` | ZSET (auctionId → endsAt ms) | `auctionRoutes.js` POST `/auctions` |
| `auction:{id}:meta` | HASH (name) | `auctionRoutes.js` POST `/auctions` |
| `auction:{id}:leader` | HASH (userId, nickname, email, price) | `bidRoutes.js` 입찰 성공 시 |
| `auction:popularity` | ZSET (auctionId → 입찰 횟수) | `bidRoutes.js` 입찰 성공 시 |

## 환경변수

| 이름 | 기본값 | 설명 |
| --- | --- | --- |
| `REDIS_URL` | (없음) | 없으면 매 틱을 건너뛴다 (경고 로그만 남김) |
| `SES_FROM_ADDRESS` | `noreply@cloudduck.cloud` | 낙찰 메일 발신 주소 (SES 도메인 인증 필요) |
| `POLL_INTERVAL_SECONDS` | `30` | 폴링 주기 |
| `AWS_REGION` | `ap-northeast-2` | SES 리전 |

## 로컬 실행

```bash
npm install
REDIS_URL=redis://localhost:6379 node worker.js
```

## 배포

GitHub Actions(`.github/workflows/deploy.yml`)가 `batch/` 변경 시 이미지를 빌드해 ECR에 올리고,
ECS 서비스(`module.batch_service`, FARGATE_SPOT)를 커밋 SHA 태그로 재배포한다.
