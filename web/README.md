# ccrew-backend

CloudDuck 경매 API 서버. **서브도메인 기반**으로 동작한다.

- API: `https://api.cloudduck.cloud`
- 프론트: `https://cloudduck.cloud` (별도 오리진)

예전에는 CloudFront 한 도메인에서 `/api/*` 경로를 ALB로 넘기는 경로 기반이었다.
지금은 호스트 자체가 API를 뜻하므로 **`/api` 접두사가 없다.**

| 예전 (경로 기반)                        | 지금 (서브도메인 기반)                       |
| --------------------------------------- | -------------------------------------------- |
| `https://cloudduck.cloud/api/auth/login` | `https://api.cloudduck.cloud/auth/login`      |
| `https://cloudduck.cloud/api/auctions`   | `https://api.cloudduck.cloud/auctions`        |
| `wss://cloudduck.cloud/ws`               | `wss://api.cloudduck.cloud/ws`                |

옛 경로로 부르면 404와 함께 바꿔야 할 경로를 알려준다.

## 엔드포인트

```
GET  /health                 ALB 헬스체크 (인증·호스트 검사 없음)
GET  /ping                   배포 확인용

POST /auth/signup
POST /auth/login
GET  /auth/me

GET  /auth/oauth/providers            키가 설정된 소셜 공급자 목록
GET  /auth/oauth/:provider            구글/카카오 동의 화면으로 302
GET  /auth/oauth/:provider/callback   공급자가 브라우저를 돌려보내는 곳

GET  /auctions               ?status=&cat=&sort=
GET  /auctions/:id
GET  /auctions/:id/related
POST /auctions               (인증)
POST /auctions/:id/bids      (인증)
GET  /auctions/:id/bids
GET  /bids/me                (인증)

GET  /me/sales | /me/purchases | /me/notifications   (인증)
GET  /admin/stats | /admin/auctions | /admin/suspicious | /admin/logs | /admin/claims  (인증)
PATCH /admin/claims/:id      (인증)

POST /uploads/presign        (인증) S3 직접 업로드용 서명 URL 발급
WS   /ws?auctionId=:id       실시간 입찰
```

## 환경변수

| 이름                | 기본값                                                          | 설명                                                                                                    |
| ------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `API_HOST`          | `api.cloudduck.cloud`                                            | 이 API가 응답할 호스트. 콤마로 여러 개 가능                                                             |
| `ENFORCE_API_HOST`  | 프로덕션이면 `true`                                              | Host 헤더 검사. ALB DNS로 직접 디버깅할 땐 `false`                                                       |
| `CORS_ORIGINS`      | `https://cloudduck.cloud,https://www.cloudduck.cloud,http://localhost:5173,http://127.0.0.1:5173` | 브라우저에서 이 API를 부를 수 있는 프론트 오리진. **스킴 포함 필수**                                     |
| `ASSET_BASE_URL`    | (없음)                                                           | 업로드 이미지를 읽는 주소 앞부분. 없으면 상대경로                                                        |
| `UPLOAD_BUCKET`     | (없음)                                                           | presign 대상 S3 버킷. 없으면 업로드 API가 503                                                            |
| `AWS_REGION`        | `ap-northeast-2`                                                 | S3 리전                                                                                                  |
| `REDIS_URL`         | (없음)                                                           | 없으면 WebSocket 브로드캐스트가 태스크 하나 안에서만 동작                                                |
| `JWT_SECRET`        | `src/authMiddleware.js` 참고                                     | 토큰 서명 키. 소셜 로그인 토큰도 같은 키로 서명한다                                                      |
| `PUBLIC_API_BASE_URL` | `https://` + `API_HOST[0]`                                     | OAuth `redirect_uri`를 만드는 기준. 공급자 콘솔 등록값과 **정확히** 같아야 한다                          |
| `FRONTEND_BASE_URL` | `CORS_ORIGINS` 의 첫 항목                                        | 소셜 로그인 후 브라우저를 돌려보낼 프론트 주소                                                           |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | (없음)                                   | 없으면 구글 버튼이 아예 안 뜬다                                                                          |
| `KAKAO_REST_API_KEY` / `KAKAO_CLIENT_SECRET` | (없음)                                  | REST API 키가 client_id 역할. client_secret은 카카오 콘솔에서 켠 경우에만                                |
| `GOOGLE_SCOPE`      | `openid email profile`                                           | 보통 건드릴 일 없다                                                                                      |
| `KAKAO_SCOPE`       | (비움)                                                           | **비워두는 게 정상.** 카카오는 scope를 안 보내면 콘솔 동의항목 설정을 그대로 쓴다                        |
| `ADMIN_EMAIL`       | `admin@cloudduck.cloud`                                          | 데모 관리자 계정                                                                                         |
| `ADMIN_PASSWORD`    | `admin1234`                                                      | 데모 관리자 비밀번호                                                                                     |
| `PORT`              | `3000`                                                           | 리슨 포트                                                                                                |

### 호스트가 갈라지면서 새로 필요해진 것

1. **CORS** — 경로 기반일 땐 같은 출처라 필요 없었다. 이제 필수.
2. **WebSocket Origin 검사** — WS 핸드셰이크에는 CORS가 적용되지 않아 직접 검사한다 (`src/realtime.js`).
3. **S3 버킷 CORS** — 브라우저가 프론트 도메인에서 S3로 직접 PUT 하므로 버킷 CORS에 `https://cloudduck.cloud` 의 `PUT` 허용이 필요하다.

## 소셜 로그인 (OAuth 2.0 직접 구현)

Cognito를 쓰지 않고 `src/oauth.js` + `src/routes/oauthRoutes.js` 에서 직접 구현했다.
방식은 **Authorization Code + PKCE**.

```
브라우저 ──[1] GET /auth/oauth/google?redirect=/mypage
            │        state 발급 → Valkey 저장, PKCE verifier는 서버만 보관
            └──302──▶ accounts.google.com 동의 화면
                          │
브라우저 ◀──302── [2] GET /auth/oauth/google/callback?code&state
                          │  state 검증(1회용) → code+verifier로 토큰 교환 → 프로필 조회
                          │  → user_identities 조회/생성 → 우리 JWT 서명
            ◀──302──▶ https://cloudduck.cloud/oauth/callback#token=...
                          프론트가 프래그먼트에서 토큰을 꺼내 localStorage에 저장
```

설계상 챙긴 것:

- **client_secret과 code_verifier는 브라우저로 나가지 않는다.** 토큰 교환·프로필 조회를 전부 서버에서 한다.
- **state는 Valkey에 두고 한 번 쓰면 지운다.** 태스크가 여러 개라 프로세스 메모리는 못 쓴다. 재사용하면 `invalid_state`.
- **토큰은 쿼리스트링이 아니라 URL 프래그먼트(`#`)로 넘긴다.** 프래그먼트는 서버로 전송되지 않아 ALB/CloudFront 액세스 로그와 Referer에 남지 않는다.
- **계정 연결은 공급자가 인증한 이메일일 때만.** 미인증 이메일까지 믿으면 남의 주소를 적어둔 소셜 계정으로 그 계정을 가져갈 수 있다. 인증 안 된 경우엔 `provider_user_id` 기반 자리표시자 이메일로 새 계정을 만든다.
- **`redirect` 파라미터는 프론트 내부 경로만 허용.** 안 그러면 우리 도메인이 오픈 리다이렉트 발판이 된다.

준비물 (공급자 콘솔):

| | 등록할 Redirect URI |
| --- | --- |
| Google Cloud Console > 사용자 인증 정보 > OAuth 클라이언트 ID(웹) | `https://api.cloudduck.cloud/auth/oauth/google/callback` |
| Kakao Developers > 카카오 로그인 > Redirect URI | `https://api.cloudduck.cloud/auth/oauth/kakao/callback` |

카카오는 **동의항목**에서 켠 것만 프로필로 내려온다. 이메일은 비즈 앱 전환/심사가 필요해서
못 켜는 경우가 많은데, 그래도 로그인은 그대로 동작한다 — `KAKAO_SCOPE`를 비워두면
앱이 scope를 아예 안 보내고 콘솔 설정을 따라간다.

이메일을 못 받은 계정은 `kakao_<id>@no-email.cloudduck.cloud` 자리표시자로 생성된다.
**이 도메인은 MX가 없어서 메일을 보내면 하드 바운스다** — SES 발송 경로(`batch/src/jobs.js`)가
이 주소를 걸러낸다. 새로 메일 보내는 코드를 추가한다면 `isPlaceholderEmail()`로 같이 걸러야 한다.

DB에는 `user_identities` 테이블이 필요한데, `src/schema.sql` 에 이미 들어 있고
부팅할 때 자동으로 만들어지므로 따로 할 일은 없다. 소셜 로그인 도입 **전부터**
데이터가 들어있던 DB에만 `db/migrations/001_oauth_identities.sql` 을 한 번 실행한다
(`CREATE TABLE IF NOT EXISTS` 는 기존 테이블을 건드리지 않기 때문).

> 도쿄(웜 스탠바이)는 읽기 전용 replica라 **소셜 첫 로그인(계정 생성)이 실패한다.**
> state도 리전별 Valkey에 저장되므로, 인가 요청과 콜백이 서로 다른 리전으로 들어가면
> `invalid_state`가 난다. 지금은 Global Accelerator의 도쿄 dial이 0%라 문제되지 않지만,
> failover 시에는 RDS promote가 끝난 뒤에 트래픽을 넘겨야 한다.

## 로컬 실행

```bash
npm install
node server.js          # http://localhost:3000, 호스트 검사 꺼짐
```

프론트는 `npm run dev` 로 5173에서 띄우면 기본 `CORS_ORIGINS` 에 이미 들어있어 그대로 붙는다.

소셜 로그인까지 로컬에서 확인하려면 주소 두 개를 로컬 기준으로 덮어쓰고,
같은 콜백 주소를 공급자 콘솔에도 추가로 등록해 둔다.

```bash
PUBLIC_API_BASE_URL=http://localhost:3000 \
FRONTEND_BASE_URL=http://localhost:5173 \
GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... \
node server.js
```

## 배포

GitHub Actions(`.github/workflows/deploy.yml`)가 `web/`, `batch/` 변경 시 이미지를 빌드해 ECR에 올리고, ECS 서비스를 커밋 SHA 태그로 재배포한다.
