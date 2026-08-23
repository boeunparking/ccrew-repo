/**
 * 인증 "도구" 모음 — 엔드포인트가 아니다.
 * Cognito가 서명한 ID 토큰을 검증하는 함수와, 라우터가 가져다 쓰는 미들웨어가 들어 있다.
 *
 * 헷갈리기 쉬운 짝: src/routes/authRoutes.js 는 실제 URL(/auth/me 등)을 정의한다.
 * 이 파일은 그 라우터를 포함한 모든 라우터가 공용으로 쓴다.
 *
 * 회원가입/로그인 자체(비밀번호 검증, 소셜 연동)는 더 이상 이 서버가 하지 않는다 —
 * 프론트가 Cognito를 직접 호출해서 토큰을 받아오고, 이 서버는 그 토큰이 우리
 * User Pool이 발급한 진짜 토큰인지만 검증한다.
 */
import { CognitoJwtVerifier } from "aws-jwt-verify";
import { ensureUserRow } from "./store.js";

// Access 토큰이 아니라 ID 토큰을 검증 대상으로 쓴다 — email/nickname은 ID 토큰에만
// 실리고, Access 토큰에는 안 실린다. cognito:groups는 둘 다 실리지만, 이 서버는
// 리소스 서버가 따로 없고 앱 클라이언트도 하나뿐이라 ID 토큰 하나로 통일하는 게
// 기존 req.user(sub/email/nickname) 모양을 그대로 유지하는 가장 단순한 방법이다.
const verifier = CognitoJwtVerifier.create({
  userPoolId: process.env.COGNITO_USER_POOL_ID,
  tokenUse: "id",
  clientId: process.env.COGNITO_CLIENT_ID,
});

function readToken(req) {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) return null;
  return header.slice(7);
}

function toReqUser(payload) {
  return {
    sub: payload.sub,
    email: payload.email,
    nickname: payload.nickname,
    // 그룹에 안 속한 사용자는 클레임 자체가 없다 — 항상 배열로 정규화한다.
    groups: payload["cognito:groups"] ?? [],
  };
}

// 로그인 뒤 처음 오는 요청에서만 DB에 프로필 row를 채워 넣는다(1시간 TTL 캐시로
// 재확인 빈도를 줄인다). auctions.seller_id/bids.user_id가 users(id) FK라 이 row가
// 필요하긴 하지만, 여기서 실패해도 요청 자체는 막지 않는다 — 정말 필요한 시점
// (경매 등록/입찰 INSERT)에 FK 위반으로 자연스럽게 막히므로 무결성은 안 깨진다.
// 도쿄(읽기 전용 replica)에서는 이 upsert가 항상 실패하는데, 이건 기존에도 도쿄에서
// 회원가입/입찰 자체가 실패하던 것과 같은 성격이라 별도 처리를 안 한다.
const userRowCache = new Map(); // sub -> 다음 재확인 시각(ms)
const USER_ROW_RECHECK_MS = 60 * 60 * 1000;

async function touchUserRow(user) {
  const next = userRowCache.get(user.sub);
  if (next && next > Date.now()) return;
  try {
    await ensureUserRow(user);
    userRowCache.set(user.sub, Date.now() + USER_ROW_RECHECK_MS);
  } catch (e) {
    console.warn(`[auth] ${user.sub} 프로필 upsert 실패 (무시) —`, e.message);
  }
}

// 로그인 필수 구간
export async function requireAuth(req, res, next) {
  const token = readToken(req);
  if (!token) return res.status(401).json({ error: "로그인이 필요합니다" });
  try {
    const payload = await verifier.verify(token);
    req.user = toReqUser(payload);
  } catch {
    return res
      .status(401)
      .json({ error: "세션이 만료되었습니다. 다시 로그인해 주세요" });
  }
  await touchUserRow(req.user);
  next();
}

// 로그인해도 되고 안 해도 되는 구간 (있으면 req.user 채움)
export async function optionalAuth(req, _res, next) {
  const token = readToken(req);
  if (token) {
    try {
      const payload = await verifier.verify(token);
      req.user = toReqUser(payload);
      await touchUserRow(req.user);
    } catch {
      /* 무시하고 비로그인으로 처리 */
    }
  }
  next();
}

// admin 그룹 멤버십이 곧 관리자 권한이다 — DB에는 role 컬럼을 두지 않는다.
// 주의: 그룹 멤버십은 로그인(토큰 발급) 시점에 스냅샷된다. 운영자가 콘솔/CLI로
// 사용자를 admin 그룹에 넣어도 그 사용자가 이미 들고 있는 토큰에는 반영되지
// 않는다 — 재로그인(또는 REFRESH_TOKEN_AUTH로 재발급)해야 반영된다.
export function requireAdmin(req, res, next) {
  if (!req.user?.groups?.includes("admin")) {
    return res.status(403).json({ error: "관리자만 접근할 수 있습니다" });
  }
  next();
}
