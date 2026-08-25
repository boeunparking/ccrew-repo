// RDS(MySQL) 기반 데이터 접근 계층.
//
// 예전엔 이 파일이 Map(users/auctions/bids)에 데이터를 직접 들고 있었다.
// 지금은 전부 pool.query로 바뀌었고, 그래서 아래 함수들은 전부 async다 —
// 호출하는 라우터 쪽에서 반드시 await를 붙여야 한다.
//
// claims/securityLogs/suspiciousBids/notifications는 아직 스키마(src/schema.sql)에
// 대응하는 테이블이 없어서 그대로 정적 목업으로 남겨뒀다 (관리자 대시보드 시연용).
// 실제 데이터로 바꾸려면 별도 테이블 설계가 먼저 필요하다.

import crypto from 'crypto';
import pool from './db.js';
import { ASSET_BASE_URL } from './config.js';

const afterSec = (s) => new Date(Date.now() + s * 1000).toISOString();

export const claims = [
  { id: 'c1', name: '상품 미배송 신고', user: 'user_a15', status: '대기' },
  { id: 'c2', name: '상품 상태 불일치', user: 'user_c92', status: '처리중' },
  { id: 'c3', name: '낙찰 후 대금 미결제', user: 'user_b77', status: '완료' },
];

export const securityLogs = [
  { t: '12:44:10', msg: 'user_m03 로그인 성공 (Seoul)' },
  { t: '12:43:52', msg: '관리자 alarm: CPU 사용률 82% 도달 (auto-scaling 트리거)' },
  { t: '12:41:30', msg: '비정상 접근 시도 차단 — IP 203.0.113.44' },
];

export const suspiciousBids = [
  { t: '12:41:02', msg: 'user_k22 → 본인 등록 상품에 입찰 시도 (차단됨)' },
  { t: '12:35:47', msg: 'user_h91 → 90초 내 7회 연속 입찰 (모니터링 대상 등록)' },
];

export const notifications = [
  { id: 'n1', message: '명일방주 텍사스 스케일 피규어 — 새로운 입찰이 등록되었습니다', createdAt: afterSec(-300) },
  { id: 'n2', message: '원피스 루피 기어5 스케일 피규어 — 낙찰되었습니다', createdAt: afterSec(-3600) },
];

// ========================================
// 순수 함수 — DB와 무관, 예전과 동일
// ========================================
export function secondsLeft(auction) {
  return Math.max(0, Math.floor((new Date(auction.endsAt).getTime() - Date.now()) / 1000));
}

export function isEnded(auction) {
  return secondsLeft(auction) === 0;
}

// "마감임박"의 기준. 목록 필터(auctionRoutes)와 입찰내역 요약(bidRoutes)이
// 같은 값을 써야 하므로 여기 한 곳에서만 정의한다.
export const CLOSING_SOON_SECONDS = 3600;

export function isClosingSoon(auction) {
  return !isEnded(auction) && secondsLeft(auction) <= CLOSING_SOON_SECONDS;
}

export function toImagePath(key) {
  if (!key) return null;
  return ASSET_BASE_URL ? `${ASSET_BASE_URL}/${key}` : `/${key}`;
}

export function toListItem(a) {
  const left = secondsLeft(a);
  return {
    id: a.id,
    name: a.name,
    brand: a.brand,
    price: a.currentPrice,
    tag: a.tag,
    secondsLeft: left,
    ended: left === 0,
    thumbnail: toImagePath(a.images[0]),
  };
}

// ========================================
// users
// ========================================
// Cognito가 회원가입/로그인을 전부 맡는다 — 여기 남은 건 인증된 사용자의 프로필을
// 우리 DB에도 한 줄 채워 넣는 것뿐이다(auctions.seller_id/bids.user_id가 users(id)를
// 참조하는 FK라서 필요하다). id는 Cognito의 sub(UUID)를 그대로 쓴다.
// 호출부(authMiddleware.js의 touchUserRow)가 1시간 TTL로 dedupe하므로 여기서는
// 매번 단순하게 upsert만 한다.
export async function ensureUserRow(user) {
  await pool.query(
    `INSERT INTO users (id, email, nickname)
     VALUES (?, ?, ?)
     ON DUPLICATE KEY UPDATE email = VALUES(email), nickname = VALUES(nickname)`,
    [user.sub, user.email, user.nickname],
  );
}

// ========================================
// auctions
// ========================================
function mapAuctionRow(row) {
  return {
    id: row.id,
    name: row.name,
    brand: row.brand,
    category: row.category,
    description: row.description,
    startPrice: row.start_price,
    currentPrice: row.current_price,
    endsAt: row.ends_at,
    sellerId: row.seller_id,
    seller: row.seller_nickname,
    tag: row.tag,
    hiddenAt: row.hidden_at,
    hiddenReason: row.hidden_reason,
    images: row.thumbnail_key ? [row.thumbnail_key] : [],
  };
}

// 목록/필터/정렬은 예전처럼 JS에서 처리한다 — 경매 수가 많지 않은 스코프라 충분하다.
//
// hidden_at이 채워진 경매(Rekognition이 REJECTED로 판정한 이미지가 붙은 경매)는
// 기본적으로 제외한다 — 공개 목록/입찰내역 요약 등 일반 사용자 화면이 이 함수를 쓴다.
// 관리자 반려 큐(listHiddenAuctions)만 그 경매들을 따로 조회한다.
export async function listAuctions({ includeHidden = false } = {}) {
  const [rows] = await pool.query(`
    SELECT a.*, u.nickname AS seller_nickname,
      (SELECT image_key FROM auction_images
        WHERE auction_id = a.id ORDER BY sort_order LIMIT 1) AS thumbnail_key
    FROM auctions a
    JOIN users u ON u.id = a.seller_id
    ${includeHidden ? '' : 'WHERE a.hidden_at IS NULL'}
  `);
  return rows.map(mapAuctionRow);
}

export async function getAuctionById(id, { includeHidden = false } = {}) {
  const [rows] = await pool.query(
    `SELECT a.*, u.nickname AS seller_nickname
     FROM auctions a JOIN users u ON u.id = a.seller_id
     WHERE a.id = ? ${includeHidden ? '' : 'AND a.hidden_at IS NULL'}`,
    [id],
  );
  if (!rows[0]) return null;

  const auction = mapAuctionRow(rows[0]);
  const [images] = await pool.query(
    'SELECT image_key FROM auction_images WHERE auction_id = ? ORDER BY sort_order',
    [id],
  );
  auction.images = images.map((i) => i.image_key);
  return auction;
}

/**
 * 관리자 반려 큐 (adminRoutes.js GET /admin/moderation).
 * 비공개 처리된 경매와, 그중 REJECTED로 찍힌 이미지 키를 같이 돌려준다.
 */
export async function listHiddenAuctions() {
  const [rows] = await pool.query(`
    SELECT a.*, u.nickname AS seller_nickname
    FROM auctions a
    JOIN users u ON u.id = a.seller_id
    WHERE a.hidden_at IS NOT NULL
    ORDER BY a.hidden_at DESC
  `);

  const auctions = rows.map(mapAuctionRow);
  if (!auctions.length) return auctions;

  const [images] = await pool.query(
    `SELECT auction_id, image_key, moderation_status, moderation_labels
     FROM auction_images
     WHERE auction_id IN (?) AND moderation_status = 'REJECTED'`,
    [auctions.map((a) => a.id)],
  );

  const rejectedByAuction = new Map();
  for (const img of images) {
    if (!rejectedByAuction.has(img.auction_id)) rejectedByAuction.set(img.auction_id, []);
    rejectedByAuction.get(img.auction_id).push({ imageKey: img.image_key, labels: img.moderation_labels });
  }

  return auctions.map((a) => ({ ...a, rejectedImages: rejectedByAuction.get(a.id) ?? [] }));
}

/**
 * 관리자가 반려 큐를 검토한 뒤 "문제 없음"으로 판단했을 때 다시 공개한다.
 * 이미지 자체(moderation_status)는 REJECTED로 남겨둔다 — Rekognition 판정 이력은
 * 그대로 보존하고, 사람이 그 판정을 오버라이드했다는 사실만 hidden_at으로 표현한다.
 */
export async function restoreAuction(id) {
  const [result] = await pool.query(
    'UPDATE auctions SET hidden_at = NULL, hidden_reason = NULL WHERE id = ? AND hidden_at IS NOT NULL',
    [id],
  );
  return result.affectedRows > 0;
}

export async function createAuction(auction) {
  await pool.query(
    `INSERT INTO auctions
      (id, name, brand, category, description, start_price, current_price, ends_at, seller_id, tag)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      auction.id, auction.name, auction.brand, auction.category, auction.description,
      auction.startPrice, auction.currentPrice, auction.endsAt, auction.sellerId, auction.tag,
    ],
  );

  if (auction.images?.length) {
    const rows = auction.images.map((key, i) => [crypto.randomUUID(), auction.id, key, i]);
    await pool.query(
      'INSERT INTO auction_images (id, auction_id, image_key, sort_order) VALUES ?',
      [rows],
    );

    await applyPendingModerationRejections(auction.id, auction.images);
  }
}

/**
 * 업로드(S3 presign)는 경매 생성보다 먼저 일어나므로, 이미지가 REJECTED로 판정되는
 * 시점이 이 경매를 만들기 "전"일 수도 있다 — Rekognition은 보통 사용자가 나머지 폼을
 * 채우는 몇 초~몇십 초 안에 끝나기 때문에 이 케이스가 오히려 흔하다.
 * image_moderation Lambda는 그때 auction_images 행이 아직 없어 직접 갱신할 수 없으므로
 * image_moderation_rejections에 image_key만으로 독립적으로 남겨둔다 — 여기서 그걸 조회해
 * 방금 만든 경매에 즉시 반영한다.
 *
 * (반대 순서 — 경매가 이미 존재하는 상태에서 판정이 나중에 도착하는 경우 — 는 Lambda가
 * auction_images/auctions를 직접 UPDATE해서 처리한다.)
 */
async function applyPendingModerationRejections(auctionId, imageKeys) {
  const [rejections] = await pool.query(
    'SELECT image_key, labels FROM image_moderation_rejections WHERE image_key IN (?)',
    [imageKeys],
  );
  if (!rejections.length) return;

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    for (const r of rejections) {
      await conn.query(
        `UPDATE auction_images SET moderation_status = 'REJECTED', moderation_labels = ?, moderated_at = NOW()
         WHERE auction_id = ? AND image_key = ?`,
        [r.labels, auctionId, r.image_key],
      );
    }

    await conn.query(
      'UPDATE auctions SET hidden_at = NOW(), hidden_reason = ? WHERE id = ? AND hidden_at IS NULL',
      ['업로드 이미지가 자동 검수에서 반려되었습니다', auctionId],
    );

    await conn.commit();
  } catch (err) {
    await conn.rollback();
    throw err;
  } finally {
    conn.release();
  }
}

// ========================================
// bids
// ========================================
export async function getBidsForAuction(auctionId) {
  const [rows] = await pool.query(
    `SELECT b.id, b.price, b.created_at, b.user_id, u.nickname
     FROM bids b JOIN users u ON u.id = b.user_id
     WHERE b.auction_id = ?
     ORDER BY b.created_at DESC`,
    [auctionId],
  );
  return rows.map((r) => ({
    id: r.id,
    price: r.price,
    createdAt: r.created_at,
    userId: r.user_id,
    nickname: r.nickname,
  }));
}

/**
 * 입찰 기록 + 현재가 갱신을 한 트랜잭션으로 처리한다 (bidRoutes.js).
 *
 * 둘을 따로 실행하면 "입찰은 남았는데 current_price는 그대로"인 반쪽 상태가 생기고,
 * 그러면 화면이 계산하는 최소 입찰가가 Valkey 기준보다 낮아져서 그 경매는 아무도
 * 입찰할 수 없게 된다. 여기서 전부 성공하거나 전부 실패하게 만들면, 호출부는
 * 실패 시 Valkey만 원복하면 두 저장소가 항상 같은 값으로 맞는다.
 */
export async function recordBid(bid) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    await conn.query(
      'INSERT INTO bids (id, auction_id, user_id, price) VALUES (?, ?, ?, ?)',
      [bid.id, bid.auctionId, bid.userId, bid.price],
    );
    await conn.query(
      'UPDATE auctions SET current_price = ? WHERE id = ?',
      [bid.price, bid.auctionId],
    );

    await conn.commit();
  } catch (err) {
    await conn.rollback();
    throw err;
  } finally {
    conn.release();
  }
}

/**
 * 경매를 관련 데이터까지 통째로 지운다 (관리자 전용).
 *
 * auction_images / bids 의 외래키에 ON DELETE CASCADE 가 없어서, 자식 행을 먼저
 * 지우지 않으면 외래키 제약으로 삭제 자체가 거부된다. 그리고 셋 중 하나라도
 * 실패했을 때 절반만 지워진 상태로 남으면 안 되므로 트랜잭션으로 묶는다.
 *
 * S3 에 남는 이미지 파일은 여기서 건드리지 않고 키만 돌려준다 —
 * DB 삭제는 원자적이어야 하는데 S3 삭제는 그 트랜잭션에 넣을 수 없기 때문이다.
 * 정리는 호출하는 쪽이 커밋 이후에 별도로 한다.
 */
export async function deleteAuction(id) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    const [images] = await conn.query(
      'SELECT image_key FROM auction_images WHERE auction_id = ?',
      [id],
    );

    await conn.query('DELETE FROM bids WHERE auction_id = ?', [id]);
    await conn.query('DELETE FROM auction_images WHERE auction_id = ?', [id]);
    const [result] = await conn.query('DELETE FROM auctions WHERE id = ?', [id]);

    await conn.commit();

    return {
      deleted: result.affectedRows > 0,
      imageKeys: images.map((i) => i.image_key),
    };
  } catch (err) {
    await conn.rollback();
    throw err;
  } finally {
    conn.release();
  }
}

export async function countAllBids() {
  const [rows] = await pool.query('SELECT COUNT(*) AS count FROM bids');
  return rows[0].count;
}
