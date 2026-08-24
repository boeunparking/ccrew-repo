/**
 * Cognito 직접 호출 계층.
 *
 * 예전에는 우리 백엔드가 비밀번호를 검증하고 JWT를 서명했다. 지금은 회원 관리 전체가
 * Cognito User Pool에 있고, 백엔드(web/)는 브라우저가 들고 온 ID 토큰이 우리 풀이
 * 발급한 진짜 토큰인지 검증만 한다(web/src/authMiddleware.js).
 *
 * 그래서 로그인 경로가 두 개다:
 *
 *   1) 이메일/비밀번호 — 커스텀 폼 + SRP (amazon-cognito-identity-js)
 *      비밀번호가 네트워크로 나가지 않는다. SRP는 비밀번호 자체가 아니라 그것으로부터
 *      유도한 증명값만 주고받는다. 화면을 우리가 그대로 들고 갈 수 있는 것도 이 방식뿐이다.
 *
 *   2) 구글 — Cognito 호스팅 UI로 리다이렉트 (authorization code + PKCE)
 *      구글 동의 화면은 XHR로 못 띄운다(CORS). 브라우저를 통째로 보내고, 돌아온
 *      code를 /oauth2/token에서 토큰으로 바꾼다.
 *
 * 두 경로가 서로 다른 곳에 토큰을 두면 "로그인했는데 로그아웃 상태"가 되기 쉬워서,
 * 토큰 보관은 아래 tokenStore 한 곳으로 통일한다. amazon-cognito-identity-js는
 * 기본적으로 자기 형식으로 localStorage에 또 쓰는데, 그 사본이 남으면 우리 저장소와
 * 어긋나므로 메모리 저장소를 물려서 껐다(MEMORY_STORAGE).
 */
import {
  CognitoUserPool,
  CognitoUser,
  AuthenticationDetails,
  CognitoUserAttribute,
} from 'amazon-cognito-identity-js';

import { COGNITO, IS_COGNITO_CONFIGURED, COGNITO_REDIRECT_URI } from './config.js';

const STORAGE_KEY = 'cd_auth';
const PKCE_KEY = 'cd_pkce';
const POST_LOGIN_KEY = 'cd_post_login';

/** 만료 직전 토큰을 그대로 쓰면 요청이 날아가는 사이에 만료된다. 2분 여유를 둔다. */
const REFRESH_MARGIN_MS = 2 * 60 * 1000;

// ────────────────────────────────────────────────────────────
// 토큰 보관
// ────────────────────────────────────────────────────────────

function decodeJwtPayload(token) {
  try {
    const base64 = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    // atob는 UTF-8을 모른다 — 닉네임에 한글이 들어가면 여기서 깨진다.
    const json = decodeURIComponent(
      atob(base64)
        .split('')
        .map((c) => `%${c.charCodeAt(0).toString(16).padStart(2, '0')}`)
        .join('')
    );
    return JSON.parse(json);
  } catch {
    return null;
  }
}

export const tokenStore = {
  read() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  },

  /**
   * refreshToken은 갱신 응답에 안 실려 온다 — 이때 기존 값을 안 물려주면
   * 첫 갱신 직후에 갱신 수단을 잃고, ID 토큰 만료(60분) 시점에 튕긴다.
   */
  write({ idToken, accessToken, refreshToken }) {
    const claims = decodeJwtPayload(idToken);
    const previous = tokenStore.read();

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        idToken,
        accessToken: accessToken ?? previous?.accessToken ?? null,
        refreshToken: refreshToken ?? previous?.refreshToken ?? null,
        // exp는 초 단위다.
        expiresAt: claims?.exp ? claims.exp * 1000 : 0,
      })
    );
  },

  clear() {
    localStorage.removeItem(STORAGE_KEY);
  },
};

/** 토큰을 들고 있는지. 유효성까지는 안 본다 — 그건 getIdToken()이 판단한다. */
export function isLoggedIn() {
  return Boolean(tokenStore.read()?.idToken);
}

// ────────────────────────────────────────────────────────────
// 토큰 갱신
// ────────────────────────────────────────────────────────────

// 여러 컴포넌트가 동시에 요청을 보내면 갱신도 동시에 여러 번 나간다.
// 하나만 나가게 묶는다 — 안 그러면 서로의 결과를 덮어쓴다.
let pendingRefresh = null;

/**
 * SRP로 받은 토큰이든 호스팅 UI로 받은 토큰이든 refresh_token은 같은 앱 클라이언트가
 * 발급한 것이라, 갱신 경로를 /oauth2/token 하나로 통일할 수 있다.
 * (앱 클라이언트에 시크릿이 없어서 Authorization 헤더도 필요 없다.)
 */
async function refreshTokens(refreshToken) {
  const res = await fetch(`${COGNITO.domain}/oauth2/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: COGNITO.clientId,
      refresh_token: refreshToken,
    }),
  });

  if (!res.ok) throw new Error('세션 갱신에 실패했습니다');

  const data = await res.json();
  tokenStore.write({
    idToken: data.id_token,
    accessToken: data.access_token,
    refreshToken: data.refresh_token, // 보통 안 온다 — write()가 기존 값을 유지한다.
  });

  return data.id_token;
}

/**
 * API 요청에 붙일 ID 토큰. 만료가 임박했으면 먼저 갱신한다.
 * 로그인 안 했거나 갱신이 실패하면 null (호출부가 로그인 화면으로 보내면 된다).
 */
export async function getIdToken() {
  const stored = tokenStore.read();
  if (!stored?.idToken) return null;

  if (stored.expiresAt - REFRESH_MARGIN_MS > Date.now()) return stored.idToken;

  // 만료됐는데 갱신 수단이 없으면 더 할 수 있는 게 없다.
  if (!stored.refreshToken) {
    tokenStore.clear();
    return null;
  }

  if (!pendingRefresh) {
    pendingRefresh = refreshTokens(stored.refreshToken)
      .catch(() => {
        // refresh 토큰도 만료(30일)됐거나 취소된 경우. 재로그인 외에 방법이 없다.
        tokenStore.clear();
        return null;
      })
      .finally(() => {
        pendingRefresh = null;
      });
  }

  return pendingRefresh;
}

/** ID 토큰에 실린 클레임. 서버에 묻지 않고 즉시 알 수 있는 값들. */
export function readClaims() {
  const stored = tokenStore.read();
  return stored?.idToken ? decodeJwtPayload(stored.idToken) : null;
}

// ────────────────────────────────────────────────────────────
// 이메일/비밀번호 — SRP
// ────────────────────────────────────────────────────────────

// 라이브러리가 자기 사본을 localStorage에 남기지 않도록 물려주는 메모리 저장소.
// (Storage 인터페이스만 맞으면 된다)
const MEMORY_STORAGE = (() => {
  let store = {};
  return {
    setItem: (k, v) => {
      store[k] = String(v);
    },
    getItem: (k) => (k in store ? store[k] : null),
    removeItem: (k) => {
      delete store[k];
    },
    clear: () => {
      store = {};
    },
  };
})();

function assertConfigured() {
  if (!IS_COGNITO_CONFIGURED) {
    throw new Error(
      '로그인 설정(Cognito)이 비어 있습니다. 배포 설정을 확인해 주세요'
    );
  }
}

function userPool() {
  assertConfigured();
  return new CognitoUserPool({
    UserPoolId: COGNITO.userPoolId,
    ClientId: COGNITO.clientId,
    Storage: MEMORY_STORAGE,
  });
}

function cognitoUser(email) {
  return new CognitoUser({
    Username: email,
    Pool: userPool(),
    Storage: MEMORY_STORAGE,
  });
}

/**
 * Cognito가 주는 영문 메시지를 그대로 띄우면 사용자가 뭘 해야 할지 알 수 없다.
 * 화면이 분기해야 하는 경우(미인증 계정 등)를 위해 code도 같이 실어 보낸다.
 */
function toFriendlyError(err) {
  const code = err?.code ?? err?.name ?? '';

  const MESSAGES = {
    NotAuthorizedException: '이메일 또는 비밀번호가 올바르지 않습니다',
    UserNotFoundException: '이메일 또는 비밀번호가 올바르지 않습니다',
    UserNotConfirmedException: '이메일 인증이 끝나지 않은 계정입니다',
    PasswordResetRequiredException: '비밀번호를 재설정해야 합니다',
    UsernameExistsException: '이미 가입된 이메일입니다',
    InvalidPasswordException: '비밀번호는 8자 이상이고 영문 소문자와 숫자를 포함해야 합니다',
    InvalidParameterException: '입력값이 올바르지 않습니다',
    CodeMismatchException: '인증코드가 올바르지 않습니다',
    ExpiredCodeException: '인증코드가 만료됐습니다. 다시 받아 주세요',
    LimitExceededException: '시도 횟수를 초과했습니다. 잠시 후 다시 시도해 주세요',
    TooManyRequestsException: '요청이 너무 잦습니다. 잠시 후 다시 시도해 주세요',
  };

  const error = new Error(MESSAGES[code] ?? err?.message ?? '요청을 처리하지 못했습니다');
  error.code = code;
  return error;
}

/**
 * 이메일/비밀번호 로그인. 성공하면 토큰을 저장하고 클레임을 돌려준다.
 * 비밀번호는 SRP 프로토콜상 네트워크로 나가지 않는다.
 */
export function login({ email, password }) {
  return new Promise((resolve, reject) => {
    let user;
    try {
      user = cognitoUser(email);
    } catch (e) {
      reject(e);
      return;
    }

    user.authenticateUser(
      new AuthenticationDetails({ Username: email, Password: password }),
      {
        onSuccess: (session) => {
          tokenStore.write({
            idToken: session.getIdToken().getJwtToken(),
            accessToken: session.getAccessToken().getJwtToken(),
            refreshToken: session.getRefreshToken().getToken(),
          });
          resolve(readClaims());
        },
        onFailure: (err) => reject(toFriendlyError(err)),
      }
    );
  });
}

/**
 * 회원가입. 여기서 끝이 아니다 — User Pool이 auto_verified_attributes로 email을
 * 잡고 있어서(terraform/cognito.tf) Cognito가 인증코드를 메일로 보내고,
 * confirmSignUp까지 통과해야 로그인할 수 있다.
 *
 * @returns {Promise<{ needsConfirmation: boolean }>}
 */
export function signUp({ email, password, nickname }) {
  return new Promise((resolve, reject) => {
    let pool;
    try {
      pool = userPool();
    } catch (e) {
      reject(e);
      return;
    }

    const attributes = [
      new CognitoUserAttribute({ Name: 'email', Value: email }),
      // 예전 백엔드가 email.split('@')[0]을 닉네임으로 쓰던 것과 같은 규칙이다.
      new CognitoUserAttribute({
        Name: 'nickname',
        Value: nickname || email.split('@')[0],
      }),
    ];

    pool.signUp(email, password, attributes, null, (err, result) => {
      if (err) {
        reject(toFriendlyError(err));
        return;
      }
      resolve({ needsConfirmation: !result?.userConfirmed });
    });
  });
}

/** 메일로 받은 인증코드 확인. */
export function confirmSignUp({ email, code }) {
  return new Promise((resolve, reject) => {
    let user;
    try {
      user = cognitoUser(email);
    } catch (e) {
      reject(e);
      return;
    }

    user.confirmRegistration(code, true, (err) => {
      if (err) reject(toFriendlyError(err));
      else resolve();
    });
  });
}

/** 인증코드 재발송. */
export function resendConfirmationCode(email) {
  return new Promise((resolve, reject) => {
    let user;
    try {
      user = cognitoUser(email);
    } catch (e) {
      reject(e);
      return;
    }

    user.resendConfirmationCode((err) => {
      if (err) reject(toFriendlyError(err));
      else resolve();
    });
  });
}

// ────────────────────────────────────────────────────────────
// 구글 — authorization code + PKCE
// ────────────────────────────────────────────────────────────

function base64UrlEncode(bytes) {
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function createPkcePair() {
  const verifierBytes = crypto.getRandomValues(new Uint8Array(32));
  const verifier = base64UrlEncode(verifierBytes);

  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return { verifier, challenge: base64UrlEncode(new Uint8Array(digest)) };
}

/**
 * 구글 로그인 시작. fetch가 아니라 브라우저를 통째로 보낸다 —
 * 구글 동의 화면은 XHR로 부르면 CORS에 막힌다.
 *
 * 퍼블릭 클라이언트(시크릿 없음)라 code가 새면 그것만으로 토큰을 받을 수 있다.
 * PKCE가 그걸 막는다 — verifier를 아는 이 브라우저만 code를 토큰으로 바꿀 수 있다.
 *
 * @param {string} redirectPath 로그인 후 돌아갈 프론트 내부 경로
 */
export async function startGoogleLogin(redirectPath = '/') {
  assertConfigured();

  const { verifier, challenge } = await createPkcePair();

  // 콜백 페이지가 읽어야 하므로 넘어가는 동안 남겨둔다.
  // state에 실어 보내지 않는 이유: state는 주소창에 노출된다.
  sessionStorage.setItem(PKCE_KEY, verifier);
  sessionStorage.setItem(POST_LOGIN_KEY, redirectPath);

  const params = new URLSearchParams({
    identity_provider: 'Google',
    response_type: 'code',
    client_id: COGNITO.clientId,
    redirect_uri: COGNITO_REDIRECT_URI,
    scope: 'openid email profile',
    code_challenge_method: 'S256',
    code_challenge: challenge,
  });

  window.location.href = `${COGNITO.domain}/oauth2/authorize?${params}`;
}

/**
 * 콜백에서 받은 code를 토큰으로 바꾼다.
 * @returns {Promise<{ redirectPath: string }>}
 */
export async function completeGoogleLogin(code) {
  assertConfigured();

  const verifier = sessionStorage.getItem(PKCE_KEY);
  const redirectPath = sessionStorage.getItem(POST_LOGIN_KEY) || '/';
  sessionStorage.removeItem(PKCE_KEY);
  sessionStorage.removeItem(POST_LOGIN_KEY);

  // 다른 탭에서 시작했거나 새로고침으로 sessionStorage가 비었을 때.
  // 교환을 시도해봤자 invalid_grant로 떨어지므로 여기서 끊는다.
  if (!verifier) throw new Error('로그인 요청이 만료됐습니다. 다시 시도해 주세요');

  const res = await fetch(`${COGNITO.domain}/oauth2/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: COGNITO.clientId,
      code,
      redirect_uri: COGNITO_REDIRECT_URI,
      code_verifier: verifier,
    }),
  });

  if (!res.ok) throw new Error('구글 계정 확인에 실패했습니다. 잠시 후 다시 시도해 주세요');

  const data = await res.json();
  tokenStore.write({
    idToken: data.id_token,
    accessToken: data.access_token,
    refreshToken: data.refresh_token,
  });

  return { redirectPath };
}

// ────────────────────────────────────────────────────────────
// 로그아웃
// ────────────────────────────────────────────────────────────

/**
 * 이 브라우저의 토큰만 지운다.
 *
 * Cognito 호스팅 UI의 /logout으로 보내지 않는 이유: 그 경로는 화면을 Cognito
 * 도메인으로 한 번 튕겼다가 돌아오게 만든다. 우리는 구글로 로그인한 사용자도
 * 결국 우리 토큰만 들고 있으므로, 지우는 것으로 충분하다.
 */
export function logout() {
  tokenStore.clear();
}
