/**
 * OAuth 2.0 클라이언트 — Cognito 없이 직접 구현한다.
 *
 * 쓰는 흐름은 Authorization Code + PKCE (RFC 7636).
 * Implicit이나 "프론트에서 access_token 받아서 백엔드로 넘기기"를 쓰지 않는 이유:
 *   - client_secret이 브라우저에 노출되면 안 된다
 *   - 프론트가 넘겨준 토큰은 "누가 발급받은 토큰인지" 서버가 알 수 없다(혼동 대리인 공격)
 * 그래서 code 교환과 프로필 조회를 전부 서버에서 한다.
 *
 * 이 파일은 "프로토콜"만 담당한다. 우리 서비스의 계정을 만들고 JWT를 발급하는
 * 정책은 src/routes/oauthRoutes.js 에 있다.
 */
import crypto from 'crypto';
import { PUBLIC_API_BASE_URL } from './config.js';

/** 인가 요청을 시작하고 콜백이 돌아올 때까지 state를 들고 있는 시간 */
const STATE_TTL_SECONDS = 600;

/** 외부(구글/카카오) 호출이 매달려 있지 않게 하는 상한 */
const HTTP_TIMEOUT_MS = 8000;

const b64url = (buf) => Buffer.from(buf).toString('base64url');

/**
 * 공급자가 이메일을 안 주거나 미인증일 때 users.email에 채우는 자리표시자의 도메인.
 * users.email이 NOT NULL UNIQUE라 뭐라도 넣어야 해서 생긴 값이다.
 *
 * MX 레코드가 없는 주소라 여기로 메일을 보내면 하드 바운스가 난다 —
 * 메일을 보내는 쪽(batch/src/jobs.js)은 이 도메인을 반드시 걸러야 한다.
 */
export const NO_EMAIL_DOMAIN = 'no-email.cloudduck.cloud';

export function isPlaceholderEmail(email) {
  return Boolean(email) && email.endsWith(`@${NO_EMAIL_DOMAIN}`);
}

// ========================================
// 공급자 정의
// ========================================
// clientId/clientSecret을 함수로 둔 이유: 컨테이너 기동 후 Secrets Manager가
// 넣어준 환경변수를 모듈 로드 시점이 아니라 요청 시점에 읽기 위해서다.
export const PROVIDERS = {
  google: {
    name: 'google',
    label: 'Google',
    authorizeUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenUrl: 'https://oauth2.googleapis.com/token',
    profileUrl: 'https://www.googleapis.com/oauth2/v3/userinfo',
    scope: () => process.env.GOOGLE_SCOPE || 'openid email profile',
    clientId: () => process.env.GOOGLE_CLIENT_ID,
    clientSecret: () => process.env.GOOGLE_CLIENT_SECRET,
    // refresh token이 필요 없는 서비스라 offline access는 요청하지 않는다.
    extraAuthParams: { access_type: 'online', prompt: 'select_account' },
    normalizeProfile(p) {
      return {
        providerUserId: String(p.sub),
        email: p.email ?? null,
        // 구글이 "이 메일 주소가 이 계정의 것임을 확인했다"고 단언한 경우만 true.
        // 기존 로컬 계정과 이어붙일지(linking) 판단하는 유일한 근거다.
        emailVerified: p.email_verified === true || p.email_verified === 'true',
        nickname: p.name || p.given_name || null,
      };
    },
  },

  kakao: {
    name: 'kakao',
    label: 'Kakao',
    authorizeUrl: 'https://kauth.kakao.com/oauth/authorize',
    tokenUrl: 'https://kauth.kakao.com/oauth/token',
    profileUrl: 'https://kapi.kakao.com/v2/user/me',
    // 기본값이 빈 문자열인 건 의도적이다 — scope를 아예 안 보내면 카카오가
    // 개발자콘솔의 동의항목 설정을 그대로 적용한다.
    // 반대로 콘솔에서 안 켠 항목(예: 심사 전인 account_email)을 scope에 적어 보내면
    // KOE205로 인가 요청 자체가 실패한다. 콘솔이 원본이고 여기는 따라가는 쪽이다.
    scope: () => process.env.KAKAO_SCOPE || '',
    clientId: () => process.env.KAKAO_REST_API_KEY,
    // 카카오는 client_secret이 "선택"이다. 콘솔에서 켠 경우에만 값이 있다.
    clientSecret: () => process.env.KAKAO_CLIENT_SECRET,
    extraAuthParams: {},
    normalizeProfile(p) {
      const account = p.kakao_account ?? {};
      const email = account.email ?? null;
      return {
        providerUserId: String(p.id),
        email,
        // 카카오는 이메일이 있어도 미인증일 수 있다. 그때는 계정 연결에 쓰지 않는다.
        emailVerified: Boolean(email) && account.is_email_verified === true,
        nickname: account.profile?.nickname || p.properties?.nickname || null,
      };
    },
  },
};

export function getProvider(name) {
  return Object.prototype.hasOwnProperty.call(PROVIDERS, name) ? PROVIDERS[name] : null;
}

/** 환경변수가 안 들어온 공급자는 버튼도 안 보여주고 엔드포인트도 404로 막는다. */
export function isConfigured(provider) {
  return Boolean(provider?.clientId());
}

export function configuredProviderNames() {
  return Object.values(PROVIDERS).filter(isConfigured).map((p) => p.name);
}

/**
 * 공급자 콘솔에 등록해야 하는 redirect_uri.
 * 토큰 교환 때도 "인가 요청 때와 같은 값"을 다시 보내야 해서(RFC 6749 §4.1.3)
 * 한 곳에서만 만든다.
 */
export function redirectUri(provider) {
  return `${PUBLIC_API_BASE_URL}/auth/oauth/${provider.name}/callback`;
}

// ========================================
// state / PKCE
// ========================================
// state는 CSRF 방어용이다. 콜백으로 돌아온 state가 "우리가 방금 발급한 것"이
// 아니면 남이 흘린 인가코드일 수 있으므로 버린다.
// ECS 태스크가 여러 개라 요청을 시작한 컨테이너와 콜백을 받는 컨테이너가 다를 수
// 있다 — 그래서 프로세스 메모리가 아니라 Valkey에 둔다.
export function createPkce() {
  const verifier = b64url(crypto.randomBytes(32));
  const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());
  return { verifier, challenge };
}

// 저장소는 두 가지다.
//   REDIS_URL 있음 → Valkey. 배포 환경은 compute.tf가 항상 넣어주므로 이쪽이다.
//   REDIS_URL 없음 → 프로세스 메모리. 로컬에 Redis를 안 띄우고도 소셜 로그인을
//                    테스트할 수 있게 하는 개발용 경로다. 태스크가 하나뿐이라 동작한다.
// 배포에서 이 폴백으로 떨어지면 안 된다 — 태스크가 2개 이상이면 인가 요청과 콜백이
// 다른 컨테이너로 갈라져 invalid_state가 산발적으로 난다. 그래서 경고를 크게 남긴다.
function memoryStore() {
  const map = new Map();
  return {
    async set(key, value, ttlSeconds) {
      map.set(key, { value, expiresAt: Date.now() + ttlSeconds * 1000 });
    },
    async take(key) {
      const hit = map.get(key);
      if (!hit) return null;
      map.delete(key); // 어차피 1회용이라 만료 여부와 무관하게 지운다
      return hit.expiresAt > Date.now() ? hit.value : null;
    },
  };
}

function valkeyStore(redis) {
  return {
    async set(key, value, ttlSeconds) {
      await redis.set(key, value, 'EX', ttlSeconds);
    },
    async take(key) {
      try {
        return await redis.getdel(key);
      } catch {
        // GETDEL은 Redis 6.2+ 명령이다. 구버전이면 읽고 지우는 걸로 대체한다.
        const raw = await redis.get(key);
        if (raw) await redis.del(key);
        return raw;
      }
    },
  };
}

let storePromise = null;

function stateStore() {
  if (storePromise) return storePromise;

  if (process.env.REDIS_URL) {
    // 동적 import라서 REDIS_URL이 없으면 Valkey 연결 자체를 시도하지 않는다.
    storePromise = import('./valkey.js').then((m) => valkeyStore(m.default));
  } else {
    console.warn(
      '[oauth] REDIS_URL이 없어 state를 프로세스 메모리에 둔다 — 로컬 개발 전용. ' +
        '배포 환경에서 이 로그가 보이면 태스크가 여러 개일 때 invalid_state가 발생한다.',
    );
    storePromise = Promise.resolve(memoryStore());
  }
  return storePromise;
}

export async function saveState(state, payload) {
  const store = await stateStore();
  await store.set(`oauth:state:${state}`, JSON.stringify(payload), STATE_TTL_SECONDS);
}

/** 한 번 쓰면 사라진다 — 같은 인가코드를 두 번 태우는 재생 공격을 막는다. */
export async function consumeState(state) {
  const store = await stateStore();
  const raw = await store.take(`oauth:state:${state}`);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

export function randomState() {
  return b64url(crypto.randomBytes(24));
}

export function buildAuthorizeUrl(provider, { state, challenge }) {
  const url = new URL(provider.authorizeUrl);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', provider.clientId());
  url.searchParams.set('redirect_uri', redirectUri(provider));
  // 비어 있으면 파라미터 자체를 빼야 한다. scope= 를 빈 값으로 보내면 공급자에 따라 에러가 난다.
  const scope = provider.scope();
  if (scope) url.searchParams.set('scope', scope);
  url.searchParams.set('state', state);
  url.searchParams.set('code_challenge', challenge);
  url.searchParams.set('code_challenge_method', 'S256');
  for (const [k, v] of Object.entries(provider.extraAuthParams)) {
    url.searchParams.set(k, v);
  }
  return url.toString();
}

// ========================================
// 토큰 교환 / 프로필 조회
// ========================================
async function postForm(url, form) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(form).toString(),
    signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
  });

  const text = await res.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = null;
  }

  if (!res.ok || !data) {
    // 공급자 응답 본문은 원인 파악에 꼭 필요하지만 사용자에게는 보내지 않는다.
    throw new Error(`token endpoint ${res.status}: ${text.slice(0, 300)}`);
  }
  return data;
}

export async function exchangeCode(provider, { code, verifier }) {
  const form = {
    grant_type: 'authorization_code',
    client_id: provider.clientId(),
    redirect_uri: redirectUri(provider),
    code,
    code_verifier: verifier,
  };

  const secret = provider.clientSecret();
  if (secret) form.client_secret = secret;

  const token = await postForm(provider.tokenUrl, form);
  if (!token.access_token) throw new Error('token endpoint에 access_token이 없다');
  return token;
}

export async function fetchProfile(provider, accessToken) {
  const res = await fetch(provider.profileUrl, {
    headers: { Authorization: `Bearer ${accessToken}` },
    signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
  });

  if (!res.ok) {
    throw new Error(`profile endpoint ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }

  const normalized = provider.normalizeProfile(await res.json());
  if (!normalized.providerUserId) throw new Error('공급자가 사용자 식별자를 주지 않았다');
  return normalized;
}
