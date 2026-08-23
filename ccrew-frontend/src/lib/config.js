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
