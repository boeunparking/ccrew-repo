/**
 * API 주소를 한 곳에서 정한다.
 *
 * 예전: CloudFront 한 도메인이 /api/*를 ALB로 넘겨서 같은 출처였다.
 * 지금: API가 api.cloudduck.cloud 라는 별도 호스트에 있으므로 절대 URL이 필요하다.
 *
 * 우선순위:
 *   1) window.__CCREW_CONFIG__.apiBaseUrl   ← public/config.js (빌드 후에도 바꿀 수 있음)
 *   2) import.meta.env.VITE_API_BASE_URL    ← 빌드 시점에 코드에 박힘
 *   3) localhost면 개발용 백엔드
 *   4) 기본값
 *
 * 1번을 맨 위에 둔 이유: Vite 환경변수는 빌드 때 코드에 박혀서 이미지 하나를
 * 개발/운영에 같이 쓸 수 없다. config.js는 컨테이너 기동 시점(혹은 S3 객체 교체)에
 * 갈아끼울 수 있어서 같은 빌드 산출물을 어느 환경에나 올릴 수 있다.
 */

const DEFAULT_API_ORIGIN = 'https://api.cloudduck.cloud';
const DEV_API_ORIGIN = 'http://localhost:3000';

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

function stripTrailingSlash(url) {
  return String(url).replace(/\/+$/, '');
}

function resolveApiBaseUrl() {
  const runtime = globalThis.window?.__CCREW_CONFIG__?.apiBaseUrl;
  if (runtime) return stripTrailingSlash(runtime);

  const buildTime = import.meta.env?.VITE_API_BASE_URL;
  if (buildTime) return stripTrailingSlash(buildTime);

  if (LOCAL_HOSTS.has(globalThis.location?.hostname)) return DEV_API_ORIGIN;

  return DEFAULT_API_ORIGIN;
}

/** 예: https://api.cloudduck.cloud (끝에 슬래시 없음) */
export const API_BASE_URL = resolveApiBaseUrl();

/** 예: wss://api.cloudduck.cloud */
export const WS_BASE_URL = API_BASE_URL.replace(/^http/, 'ws');

/**
 * Cognito 설정.
 *
 * 회원가입/로그인은 백엔드를 거치지 않고 브라우저가 Cognito를 직접 호출한다.
 * 그래서 이 값들이 없으면 API 주소가 맞아도 로그인 자체가 불가능하다.
 *
 * API 주소와 달리 기본값을 둘 수 없다 — user pool id 와 client id 는 AWS 가
 * 생성 시점에 부여하는 값이라 코드가 미리 알 방법이 없다. 운영에서는 deploy.yml 의
 * frontend 잡이 SSM 에서 읽어 dist/config.js 에 써 넣는다(terraform/cognito.tf).
 *
 * 셋 다 브라우저에 그대로 노출돼도 되는 공개값이다 — 앱 클라이언트를
 * generate_secret = false 로 만든 퍼블릭 클라이언트라 시크릿이 애초에 없다.
 */
const cognitoRuntime = globalThis.window?.__CCREW_CONFIG__?.cognito ?? {};

export const COGNITO = {
  userPoolId: cognitoRuntime.userPoolId || import.meta.env?.VITE_COGNITO_USER_POOL_ID || '',
  clientId: cognitoRuntime.clientId || import.meta.env?.VITE_COGNITO_CLIENT_ID || '',
  domain: stripTrailingSlash(
    cognitoRuntime.domain || import.meta.env?.VITE_COGNITO_DOMAIN || ''
  ),
};

/**
 * 설정이 다 채워졌는지. 화면이 "로그인이 안 된다"와 "설정이 안 됐다"를 구분해서
 * 보여줄 수 있도록 노출한다 — 후자는 사용자가 아무리 다시 시도해도 안 풀린다.
 */
export const IS_COGNITO_CONFIGURED = Boolean(
  COGNITO.userPoolId && COGNITO.clientId && COGNITO.domain
);

/**
 * 구글 로그인이 끝난 뒤 Cognito가 브라우저를 돌려보내는 주소.
 * terraform 의 aws_cognito_user_pool_client.callback_urls 에 등록된 값과
 * 정확히 일치해야 한다 — 하나라도 다르면 Cognito가 redirect_mismatch 로 거절한다.
 * (terraform/cognito.tf 의 local.cognito_callback_urls)
 */
export const COGNITO_REDIRECT_URI = `${globalThis.location?.origin ?? ''}/oauth/callback`;
