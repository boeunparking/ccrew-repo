/**
 * 서브도메인 기반 배포 설정을 한 곳에 모은다.
 *
 * 예전: CloudFront 한 도메인에서 /api/* 경로를 ALB로 넘기는 "경로 기반"
 * 지금: api.cloudduck.cloud 라는 별도 호스트로 들어오는 "서브도메인 기반"
 *
 * 호스트가 갈라지면서 프론트와 API의 출처(origin)가 달라졌으므로
 * CORS와 WebSocket origin 검사가 필수가 됐다.
 */

function toList(value) {
  return (value ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

/** 이 API가 응답할 호스트. 여러 개면 콤마로 구분한다. */
export const API_HOSTS = (
  toList(process.env.API_HOST).length
    ? toList(process.env.API_HOST)
    : ['api.cloudduck.cloud']
).map((h) => h.toLowerCase());

/** 로컬 개발·컨테이너 내부 진단용으로 항상 열어두는 호스트 */
const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '[::1]']);

/**
 * Host 헤더 검사 켜기/끄기.
 * 기본값은 프로덕션에서만 켜기. ALB DNS로 직접 찔러보며 디버깅할 때는
 * ENFORCE_API_HOST=false 로 잠시 끌 수 있다.
 */
export const ENFORCE_API_HOST = process.env.ENFORCE_API_HOST
  ? process.env.ENFORCE_API_HOST !== 'false'
  : process.env.NODE_ENV === 'production';

export function isAllowedHost(hostname) {
  if (!hostname) return false;
  const h = hostname.toLowerCase();
  return API_HOSTS.includes(h) || LOCAL_HOSTS.has(h);
}

/**
 * 브라우저에서 이 API를 호출할 수 있는 프론트 출처.
 * 스킴까지 포함한 완전한 origin으로 적어야 한다. (예: https://www.cloudduck.cloud)
 */
// 사용자가 보게 되는 프론트 주소는 www 하나다. apex(cloudduck.cloud)로 들어와도
// CloudFront 가 HTML 을 내려주기 전에 301 로 www 로 보내므로, 브라우저 출처가
// apex 인 채로 이 API 를 부르는 상황이 생기지 않는다 — 목록에 둘 이유가 없다.
//
// 예외는 전환 시점에 apex 로 앱을 이미 띄워둔 탭뿐이다. 그 탭은 새로고침하면
// www 로 넘어간다. 그 잠깐까지 받아주고 싶으면 CORS_ORIGINS 환경변수로 apex 를
// 임시로 추가할 수 있다(코드 수정 없이 ECS 태스크 정의만 바꾸면 된다).
export const ALLOWED_ORIGINS = toList(process.env.CORS_ORIGINS).length
  ? toList(process.env.CORS_ORIGINS)
  : [
      'https://www.cloudduck.cloud',
      'http://localhost:5173',
      'http://127.0.0.1:5173',
    ];

export function isAllowedOrigin(origin) {
  if (!origin) return false;
  // '*' 를 넣으면 전부 허용 (테스트용. 프로덕션에서는 쓰지 말 것)
  if (ALLOWED_ORIGINS.includes('*')) return true;
  return ALLOWED_ORIGINS.includes(origin);
}

/**
 * 업로드 이미지를 브라우저가 받아갈 주소의 앞부분.
 * 프론트 도메인의 CloudFront가 /auctions/* 를 업로드 버킷으로 넘기고 있으면
 * 비워둬도 되지만(상대경로), 이미지 전용 도메인을 쓸 거라면 여기에 넣는다.
 * 예: https://cdn.cloudduck.cloud
 */
export const ASSET_BASE_URL = (process.env.ASSET_BASE_URL ?? '').replace(/\/+$/, '');

/**
 * 이 API가 밖에서 보이는 절대 주소.
 *
 * OAuth redirect_uri는 구글/카카오 콘솔에 등록한 문자열과 한 글자도 다르면 안 되는데,
 * 요청의 Host 헤더로 만들면 ALB DNS나 헬스체크 호스트가 섞여 들어와서 어긋난다.
 * 그래서 요청과 무관하게 설정으로 고정한다.
 * 로컬 개발은 PUBLIC_API_BASE_URL=http://localhost:3000 으로 띄운다.
 */
export const PUBLIC_API_BASE_URL = (
  process.env.PUBLIC_API_BASE_URL ?? `https://${API_HOSTS[0]}`
).replace(/\/+$/, '');

/**
 * 소셜 로그인이 끝난 뒤 브라우저를 되돌려 보낼 프론트 주소.
 * 기본값은 CORS 허용 목록의 첫 항목 — 운영 도메인이 거기 먼저 온다.
 */
export const FRONTEND_BASE_URL = (
  process.env.FRONTEND_BASE_URL ??
  ALLOWED_ORIGINS[0] ??
  'https://www.cloudduck.cloud'
).replace(/\/+$/, '');
