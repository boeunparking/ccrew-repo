// API는 api.cloudduck.cloud 라는 별도 호스트에 있다.
// 경로 기반(/api/*)이 아니라 서브도메인 기반이므로 모든 요청이 교차 출처다.
// 주소는 config.js가 정하고(런타임 교체 가능), 여기서는 경로만 신경 쓴다.
import { API_BASE_URL } from './config.js';
import { getIdToken, isLoggedIn, logout as cognitoLogout } from './cognito.js';

/**
 * 토큰은 이제 이 파일이 직접 들고 있지 않다 — 발급도 갱신도 Cognito 쪽이고,
 * 보관은 lib/cognito.js의 tokenStore 한 곳으로 모았다.
 * 여기서는 기존 호출부가 쓰던 모양만 유지한다.
 */
export const auth = {
  isLoggedIn,
  clear: cognitoLogout,
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
    // ID 토큰은 60분이면 만료된다. getIdToken()이 만료가 임박했으면 먼저 갱신하고,
    // 갱신도 불가능하면 null을 준다 — 그 경우 요청을 보내봤자 401이므로 여기서 끊는다.
    const token = await getIdToken();
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
  // 로그인·회원가입은 이제 이 함수를 아예 거치지 않는다(브라우저가 Cognito를 직접
  // 호출한다 — lib/cognito.js). 그래서 여기 오는 401은 토큰이 거절된 경우뿐이지만,
  // 조건은 그대로 둔다: needAuth가 아닌 요청의 401까지 "세션 만료"로 덮어쓰면
  // 서버가 보낸 진짜 이유가 버려진다.
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
  // signup/login은 여기 없다 — 브라우저가 Cognito를 직접 호출한다(lib/cognito.js).
  // 백엔드에 남은 인증 엔드포인트는 "이 토큰이 누구냐"를 되묻는 /auth/me 하나뿐이다.
  logout: () => auth.clear(),
  me: () => request('/auth/me', { auth: true }),

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

  // 반려 큐 — image_moderation Lambda가 REJECTED로 판정해 자동 비공개된 경매들.
  adminModeration: () => request('/admin/moderation', { auth: true }),
  // 검토 결과 오탐이면 다시 공개한다.
  adminRestoreAuction: (id) =>
    request(`/admin/moderation/${id}/restore`, { method: 'PATCH', auth: true }),

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
