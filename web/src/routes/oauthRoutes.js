/**
 * 소셜 로그인 엔드포인트 (authRoutes.js 아래 /auth/oauth 로 붙는다).
 *
 *   GET /auth/oauth/providers               — 프론트가 어떤 버튼을 그릴지 물어본다
 *   GET /auth/oauth/:provider               — 공급자 동의 화면으로 302
 *   GET /auth/oauth/:provider/callback      — 공급자가 브라우저를 돌려보내는 곳
 *
 * 콜백은 XHR이 아니라 브라우저 최상위 이동이다. 그래서 JSON을 반환하지 않고
 * 프론트의 /oauth/callback 으로 302를 보낸다. 우리 JWT는 쿼리스트링이 아니라
 * URL 프래그먼트(#)에 실어 보낸다 — 프래그먼트는 서버로 전송되지 않아서
 * ALB/CloudFront 액세스 로그나 Referer 헤더에 토큰이 남지 않는다.
 *
 * 프로토콜 자체(PKCE, 토큰 교환, 프로필 조회)는 src/oauth.js 에 있다.
 */
import { Router } from 'express';
import crypto from 'crypto';
import {
  getProvider,
  isConfigured,
  configuredProviderNames,
  createPkce,
  randomState,
  saveState,
  consumeState,
  buildAuthorizeUrl,
  exchangeCode,
  fetchProfile,
  NO_EMAIL_DOMAIN,
} from '../oauth.js';
import { signToken } from '../authMiddleware.js';
import {
  findUserByEmail,
  findUserByIdentity,
  createUser,
  linkIdentity,
} from '../store.js';
import { FRONTEND_BASE_URL } from '../config.js';

const router = Router();

const CALLBACK_PATH = '/oauth/callback';

/**
 * 로그인 후 돌아갈 곳. 프론트 내부 경로만 허용한다.
 * 이걸 검사하지 않으면 /auth/oauth/google?redirect=https://evil.example 로
 * 우리 도메인을 발판 삼는 오픈 리다이렉트가 된다.
 * '//host' 는 브라우저가 프로토콜 상대 URL로 읽으므로 같이 막는다.
 */
function safeRedirectPath(value) {
  if (typeof value !== 'string') return '/';
  if (!value.startsWith('/') || value.startsWith('//')) return '/';
  return value;
}

function toFrontend(res, hashParams) {
  const hash = new URLSearchParams(hashParams).toString();
  res.redirect(`${FRONTEND_BASE_URL}${CALLBACK_PATH}#${hash}`);
}

/** 실패도 프론트로 돌려보낸다 — API가 날 JSON을 뱉으면 사용자는 흰 화면만 본다. */
function fail(res, code, detail) {
  if (detail) console.warn(`[oauth] ${code}: ${detail}`);
  toFrontend(res, { error: code });
}

// 프론트가 켜져 있는 공급자만 버튼으로 그리게 한다.
// 환경변수를 안 넣은 채 배포해도 "눌렀더니 404"가 나지 않는다.
router.get('/providers', (_req, res) => {
  res.json({ providers: configuredProviderNames() });
});

// ========================================
// 1단계 — 동의 화면으로 보내기
// ========================================
router.get('/:provider', async (req, res, next) => {
  const provider = getProvider(req.params.provider);
  if (!provider || !isConfigured(provider)) {
    return res.status(404).json({ error: '지원하지 않는 소셜 로그인입니다' });
  }

  try {
    const state = randomState();
    const { verifier, challenge } = createPkce();

    // verifier는 절대 브라우저로 나가지 않는다. 서버가 들고 있다가
    // 토큰 교환 때 제출해서 "인가 요청을 시작한 게 나"임을 증명한다.
    await saveState(state, {
      provider: provider.name,
      verifier,
      redirect: safeRedirectPath(req.query.redirect),
    });

    res.redirect(buildAuthorizeUrl(provider, { state, challenge }));
  } catch (e) {
    next(e);
  }
});

// ========================================
// 2단계 — 콜백
// ========================================
router.get('/:provider/callback', async (req, res) => {
  const provider = getProvider(req.params.provider);
  if (!provider || !isConfigured(provider)) {
    return res.status(404).json({ error: '지원하지 않는 소셜 로그인입니다' });
  }

  // 사용자가 동의 화면에서 취소한 경우도 여기로 온다.
  if (req.query.error) {
    return fail(res, 'denied', `${req.query.error} ${req.query.error_description ?? ''}`);
  }

  const { code, state } = req.query;
  if (!code || !state) return fail(res, 'invalid_request', 'code/state 누락');

  // state 검증. 없거나(만료·재사용) 다른 공급자 것이면 여기서 끝낸다.
  const saved = await consumeState(String(state));
  if (!saved) return fail(res, 'invalid_state', '만료됐거나 이미 사용한 state');
  if (saved.provider !== provider.name) return fail(res, 'invalid_state', '공급자 불일치');

  try {
    const token = await exchangeCode(provider, { code: String(code), verifier: saved.verifier });
    const profile = await fetchProfile(provider, token.access_token);
    const user = await resolveUser(provider.name, profile);

    toFrontend(res, {
      token: signToken(user),
      redirect: saved.redirect ?? '/',
    });
  } catch (e) {
    fail(res, 'exchange_failed', e.message);
  }
});

// ========================================
// 계정 결정 규칙
// ========================================
// 1) 이미 연결된 소셜 계정이면 그 계정으로 로그인
// 2) 공급자가 "인증됐다"고 단언한 이메일이 기존 계정과 같으면 그 계정에 연결
// 3) 아니면 새 계정을 만든다
//
// 2번에서 emailVerified를 반드시 확인해야 한다. 미인증 이메일까지 믿으면
// 공격자가 남의 이메일을 적어둔 소셜 계정으로 그 사람 계정을 가져갈 수 있다.
async function resolveUser(providerName, profile) {
  const existing = await findUserByIdentity(providerName, profile.providerUserId);
  if (existing) return existing;

  if (profile.email && profile.emailVerified) {
    const byEmail = await findUserByEmail(profile.email);
    if (byEmail) {
      await linkIdentity({
        userId: byEmail.id,
        provider: providerName,
        providerUserId: profile.providerUserId,
        email: profile.email,
      });
      return byEmail;
    }
  }

  // users.email은 UNIQUE NOT NULL이라 뭐라도 채워야 한다. 다만 공급자가 인증하지 않은
  // 이메일을 그대로 쓰면 안 된다 — 남의 주소를 적어둔 계정이 UNIQUE 충돌을 통해
  // 그 사람 자리를 차지할 수 있다. 인증된 값이 아니면 자리표시자를 쓴다.
  // (카카오는 동의 항목 설정에 따라 이메일이 아예 안 내려오기도 한다)
  const usable = profile.email && profile.emailVerified;
  const user = {
    id: crypto.randomUUID(),
    email: usable
      ? profile.email
      : `${providerName}_${profile.providerUserId}@${NO_EMAIL_DOMAIN}`,
    passwordHash: null, // 비밀번호 로그인은 못 한다 — 소셜로만 들어온다
    nickname: profile.nickname || profile.email?.split('@')[0] || `${providerName}_user`,
    role: 'user',
  };

  try {
    await createUser(user);
  } catch (e) {
    // 같은 사람이 탭 두 개에서 동시에 눌러 INSERT가 겹친 경우.
    // 먼저 들어간 쪽이 이미 계정을 만들었으니 그걸 쓴다.
    if (e.code !== 'ER_DUP_ENTRY') throw e;
    const raced = await findUserByIdentity(providerName, profile.providerUserId);
    if (raced) return raced;
    // 이메일이 겹쳐서 났을 수도 있다. 단, 여기서 기존 계정을 돌려주는 건
    // 인증된 이메일일 때만 안전하다 — 아니면 위의 연결 규칙을 우회하는 셈이 된다.
    if (usable) {
      const byEmail = await findUserByEmail(user.email);
      if (byEmail) return byEmail;
    }
    throw e;
  }

  await linkIdentity({
    userId: user.id,
    provider: providerName,
    providerUserId: profile.providerUserId,
    email: profile.email,
  });
  return user;
}

export default router;
