// API는 api.cloudduck.cloud 라는 별도 호스트에 있다.
// 경로 기반(/api/*)이 아니라 서브도메인 기반이므로 모든 요청이 교차 출처다.
// 주소는 config.js가 정하고(런타임 교체 가능), 여기서는 경로만 신경 쓴다.
import { API_BASE_URL } from './config.js';

const TOKEN_KEY = 'cd_token';

export const auth = {
  get: () => localStorage.getItem(TOKEN_KEY),
  set: (t) => localStorage.setItem(TOKEN_KEY, t),
  clear: () => localStorage.removeItem(TOKEN_KEY),
  isLoggedIn: () => Boolean(localStorage.getItem(TOKEN_KEY)),
};

/**
 * 화면이 원인을 구분할 수 있도록 HTTP 상태를 에러에 실어 보낸다.
 * 메시지만 던지면 "권한 없음(403)"과 "토큰 문제(401)"가 똑같이 보여서
 * 어느 쪽인지 알 수 없다 — 실제로 관리자 화면에서 그것 때문에 원인을 못 좁혔다.
 *
 * status가 없는 에러는 요청을 보내기도 전에 막힌 경우(토큰 없음, 네트워크 실패)다.
 */
function apiError(message, status) {
  const err = new Error(message);
  if (status) err.status = status;
  return err;
}

async function request(path, { method = 'GET', body, auth: needAuth = false } = {}) {
  const headers = {};
  if (body) headers['Content-Type'] = 'application/json';

  if (needAuth) {
    const token = auth.get();
    if (!token) throw apiError('로그인이 필요합니다');
    headers.Authorization = `Bearer ${token}`;
  }

  let res;
  try {
    res = await fetch(`${API_BASE_URL}${path}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    // 교차 출처가 되면서 CORS 차단·DNS 실패도 여기로 떨어진다.
    // fetch가 던지는 'Failed to fetch'만 보여주면 원인을 알기 어렵다.
    throw apiError(`서버(${API_BASE_URL})에 연결하지 못했습니다`);
  }

  const data = await res.json().catch(() => ({}));

  // 401을 "세션 만료"로 해석해도 되는 건 우리가 토큰을 보낸 요청뿐이다.
  //
  // 토큰을 안 보내는 요청(로그인·회원가입)의 401은 자격증명이 틀렸다는 뜻인데,
  // 예전에는 여기서 본문도 안 읽고 전부 "세션이 만료되었습니다"로 덮어썼다.
  // 그래서 비밀번호를 틀리면 로그인 화면에 "세션이 만료되었습니다"가 떴고,
  // 서버가 보낸 "이메일 또는 비밀번호가 올바르지 않습니다"는 버려졌다.
  if (res.status === 401 && needAuth) {
    auth.clear();
    throw apiError(data.error ?? '세션이 만료되었습니다. 다시 로그인해 주세요', 401);
  }

  if (!res.ok) throw apiError(data.error ?? '요청을 처리하지 못했습니다', res.status);
  return data;
}

export const api = {
  ping: () => request('/ping'),

  // --- 인증 ---
  signup: (form) => request('/auth/signup', { method: 'POST', body: form }),
  login: async (form) => {
    const data = await request('/auth/login', { method: 'POST', body: form });
    auth.set(data.token);
    return data.user;
  },
  logout: () => auth.clear(),
  me: () => request('/auth/me', { auth: true }),

  // --- 소셜 로그인 ---
  // 백엔드에 키가 들어간 공급자만 내려온다 (예: ['google', 'kakao']).
  oauthProviders: () => request('/auth/oauth/providers'),

  /**
   * 여기는 fetch가 아니라 브라우저를 통째로 보내는 주소다.
   * XHR로 부르면 구글/카카오 동의 화면이 CORS에 막힌다 — 반드시 location 이동.
   */
  oauthStartUrl: (provider, redirectPath = '/') =>
    `${API_BASE_URL}/auth/oauth/${provider}?redirect=${encodeURIComponent(redirectPath)}`,

  // --- 경매 ---
  listAuctions: (params = {}) => {
    const qs = new URLSearchParams(
      Object.entries(params).filter(([, v]) => v != null && v !== '')
    ).toString();
    return request(`/auctions${qs ? `?${qs}` : ''}`);
  },
  getAuction: (id) => request(`/auctions/${id}`),
  getRelated: (id) => request(`/auctions/${id}/related`),
  createAuction: (payload) => request('/auctions', { method: 'POST', body: payload, auth: true }),

  // --- 입찰 ---
  placeBid: (id, price) =>
    request(`/auctions/${id}/bids`, { method: 'POST', body: { price }, auth: true }),
  getBidHistory: (id) => request(`/auctions/${id}/bids`),
  myBids: () => request('/bids/me', { auth: true }),

  // --- 마이페이지 ---
  mySales: () => request('/me/sales', { auth: true }),
  myPurchases: () => request('/me/purchases', { auth: true }),
  myNotifications: () => request('/me/notifications', { auth: true }),

  // --- 관리자 ---
  adminStats: () => request('/admin/stats', { auth: true }),
  adminAuctions: () => request('/admin/auctions', { auth: true }),
  adminSuspicious: () => request('/admin/suspicious', { auth: true }),
  adminLogs: () => request('/admin/logs', { auth: true }),
  adminClaims: () => request('/admin/claims', { auth: true }),
  advanceClaim: (id) => request(`/admin/claims/${id}`, { method: 'PATCH', auth: true }),
  // 입찰·이미지까지 같이 지워지고 되돌릴 수 없다. 호출 전에 반드시 확인을 받을 것.
  adminDeleteAuction: (id) => request(`/admin/auctions/${id}`, { method: 'DELETE', auth: true }),

  // --- 이미지 업로드 ---
  // 파일이 백엔드 컨테이너를 거치지 않고 브라우저에서 S3로 바로 올라간다
  uploadImage: async (file) => {
    const { uploadUrl, key, publicUrl } = await request('/uploads/presign', {
      method: 'POST',
      body: { contentType: file.type, fileName: file.name },
      auth: true,
    });

    const put = await fetch(uploadUrl, {
      method: 'PUT',
      headers: { 'Content-Type': file.type },
      body: file,
    });
    if (!put.ok) throw new Error('이미지 업로드에 실패했습니다');

    return { key, publicUrl };
  },
};
