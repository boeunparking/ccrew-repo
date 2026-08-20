// RDS(MySQL) 기반 데이터 접근 계층.
//
// 예전엔 이 파일이 Map(users/auctions/bids)에 데이터를 직접 들고 있었다.
// 지금은 전부 pool.query로 바뀌었고, 그래서 아래 함수들은 전부 async다 —
// 호출하는 라우터 쪽에서 반드시 await를 붙여야 한다.
//
// claims/securityLogs/suspiciousBids/notifications는 아직 스키마(db/schema.sql)에
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
export async function findUserByEmail(email) {
  const [rows] = await pool.query('SELECT * FROM users WHERE email = ?', [email]);
  if (!rows[0]) return null;
  return mapUserRow(rows[0]);
}

export async function findUserById(id) {
  const [rows] = await pool.query('SELECT * FROM users WHERE id = ?', [id]);
  if (!rows[0]) return null;
  return mapUserRow(rows[0]);
}

// 재배포 때마다 같은 admin 계정으로 다시 뜨는 걸 허용한다 (server.js warmup용).
export async function upsertUser(user) {
  await pool.query(
    `INSERT INTO users (id, email, password_hash, nickname, role)
     VALUES (?, ?, ?, ?, ?)
     ON DUPLICATE KEY UPDATE password_hash = VALUES(password_hash), role = VALUES(role)`,
    [user.id, user.email, user.passwordHash, user.nickname, user.role],
  );
}

export async function createUser(user) {
  await pool.query(
    'INSERT INTO users (id, email, password_hash, nickname, role) VALUES (?, ?, ?, ?, ?)',
    [user.id, user.email, user.passwordHash, user.nickname, user.role],
  );
}

function mapUserRow(row) {
  return {
    id: row.id,
    email: row.email,
    passwordHash: row.password_hash,
    nickname: row.nickname,
    role: row.role,
  };
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
    images: row.thumbnail_key ? [row.thumbnail_key] : [],
  };
}

// 목록/필터/정렬은 예전처럼 JS에서 처리한다 — 경매 수가 많지 않은 스코프라 충분하다.
export async function listAuctions() {
  const [rows] = await pool.query(`
    SELECT a.*, u.nickname AS seller_nickname,
      (SELECT image_key FROM auction_images
        WHERE auction_id = a.id ORDER BY sort_order LIMIT 1) AS thumbnail_key
    FROM auctions a
    JOIN users u ON u.id = a.seller_id
  `);
  return rows.map(mapAuctionRow);
}

export async function getAuctionById(id) {
  const [rows] = await pool.query(
    `SELECT a.*, u.nickname AS seller_nickname
     FROM auctions a JOIN users u ON u.id = a.seller_id
     WHERE a.id = ?`,
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
  }
}

export async function updateAuctionCurrentPrice(auctionId, price) {
  await pool.query('UPDATE auctions SET current_price = ? WHERE id = ?', [price, auctionId]);
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

export async function createBid(bid) {
  await pool.query(
    'INSERT INTO bids (id, auction_id, user_id, price) VALUES (?, ?, ?, ?)',
    [bid.id, bid.auctionId, bid.userId, bid.price],
  );
}

export async function countAllBids() {
  const [rows] = await pool.query('SELECT COUNT(*) AS count FROM bids');
  return rows[0].count;
}
