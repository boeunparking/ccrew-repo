# 클라우드 Duck — React + Vite 프론트엔드

## 실행 방법

```bash
npm install
npm run dev     # http://localhost:5173
```

백엔드도 같이 띄워야 한다 (`ccrew-backend` 에서 `node server.js` → 3000 포트).
개발용 프록시는 없다. 프론트가 `http://localhost:3000` 으로 직접(교차 출처) 호출하고,
백엔드 기본 `CORS_ORIGINS` 에 `http://localhost:5173` 이 들어 있어서 통과한다.

## API 주소 설정

API는 `https://api.cloudduck.cloud` 라는 **별도 서브도메인**에 있다.
(예전에는 같은 도메인의 `/api/*` 경로였다.)

주소는 [src/lib/config.js](src/lib/config.js)가 이 순서로 정한다.

| 순위 | 출처 | 언제 쓰나 |
|---|---|---|
| 1 | `window.__CCREW_CONFIG__.apiBaseUrl` ([public/config.js](public/config.js)) | 빌드 후에 바꿔야 할 때 |
| 2 | `VITE_API_BASE_URL` | 빌드 시점에 고정해도 될 때 |
| 3 | `http://localhost:3000` | 호스트가 localhost일 때 (개발) |
| 4 | `https://api.cloudduck.cloud` | 기본값 |

1번을 맨 위에 둔 이유: Vite 환경변수는 빌드 때 코드에 박혀서 이미지 하나를 여러 환경에
쓸 수 없다. `config.js` 는 컨테이너가 뜰 때(`API_BASE_URL` 환경변수) 또는 S3 객체 교체로
갈아끼울 수 있어서 **같은 빌드 산출물을 개발/스테이징/운영에 그대로 올릴 수 있다.**

`config.js` 는 절대 캐시하면 안 된다 ([nginx.conf](nginx.conf)에 `no-store` 설정되어 있음).

## 페이지 구성

| 경로 | 페이지 |
|---|---|
| `/` | 홈페이지 |
| `/signup` | 회원가입 |
| `/login` | 로그인 (이메일 + 구글·카카오 소셜 로그인) |
| `/oauth/callback` | 소셜 로그인 후 백엔드가 돌려보내는 곳. 화면은 없고 토큰만 저장한다 |
| `/auctions` | 경매 상품 목록 |
| `/auctions/:id` | 경매 상품 상세 (입찰 폼, 실시간 이력) |
| `/auctions/new` | 경매 상품 등록 (판매자) |
| `/bids` | 입찰 내역 (주식창 스타일, 실시간 시세 시뮬레이션) |
| `/mypage` | 마이페이지 (판매/구매/알림 탭) |
| `/admin` | 관리자 대시보드 (실시간 시뮬레이션) |

## 소셜 로그인

로그인/회원가입 화면의 소셜 버튼은 [components/SocialLogin.jsx](src/components/SocialLogin.jsx)다.
**어떤 버튼을 그릴지는 백엔드가 정한다** — `GET /auth/oauth/providers` 가 키가 설정된
공급자만 내려주므로, 환경변수를 안 넣은 채 배포해도 눌렀을 때 404가 나는 버튼이 남지 않는다.

버튼을 누르면 `fetch`가 아니라 `window.location`으로 백엔드에 **페이지 이동**한다.
XHR로 부르면 구글/카카오 동의 화면이 CORS에 막힌다.

돌아올 때 토큰은 쿼리스트링이 아니라 URL 프래그먼트(`#token=...`)로 온다.
프래그먼트는 서버로 전송되지 않아 액세스 로그·Referer에 토큰이 남지 않는다.
[OAuthCallback.jsx](src/pages/OAuthCallback.jsx)가 값을 꺼낸 뒤 `history.replaceState`로
주소창에서 즉시 지운다.

`/oauth/callback` 은 SPA 경로라 정적 호스팅이 index.html로 폴백해야 한다
(CloudFront 쪽에 403/404 → `/index.html` 설정이 이미 있다).

## 다음 단계 (실제 연동 시)

- `TODO:` 주석이 달린 부분(회원가입, 로그인, 입찰, 경매 등록)에 실제 API 호출 연결
- `AuctionDetail.jsx`, `BidHistory.jsx`, `AdminDashboard.jsx`의 `setInterval` 폴링 로직을
  WebSocket 구독 또는 실제 API 폴링으로 교체
- 인증 상태에 따라 `Nav` 컴포넌트의 로그인/회원가입 버튼을 로그아웃/마이페이지로 전환하는 로직 추가
"# ccrew-frontend" 
