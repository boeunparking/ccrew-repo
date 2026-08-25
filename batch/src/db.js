// RDS(MySQL) 커넥션 풀.
//
// batch는 원래 Redis만 보는 워커였지만, 지금은 두 가지 이유로 RDS를 본다.
//   1. 이미지 반려(hidden_at) 상태는 RDS에만 있다 — 반려된 경매의 낙찰 메일을 막는다.
//   2. 낙찰/패찰 판정과 알림 기록. 예전엔 Valkey의 auction:{id}:leader 해시만 보고
//      낙찰자를 정했는데, Valkey는 캐시라 키가 사라지면 낙찰자를 통째로 잃는다.
//      입찰의 법적 기록은 bids 테이블이므로 거기서 뽑는 게 맞다.

import crypto from 'crypto';
import mysql from 'mysql2/promise';

const pool = mysql.createPool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT ?? 3306),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME ?? 'cloud_duck',

  waitForConnections: true,
  // web과 달리 요청당 커넥션이 아니라 30초 틱마다 짧게 몇 건만 조회하므로 적게 잡는다.
  connectionLimit: 3,
});

export default pool;

/**
 * 경매가 반려(hidden_at 존재) 상태인지 확인한다.
 * DB 조회가 실패하면(RDS 일시 장애 등) false를 반환해 메일 발송을 막지 않는다 —
 * 이 체크는 오발송을 줄이기 위한 안전장치일 뿐, 없어도 기존 동작(Redis만 봄)과
 * 같아지므로 낙찰 알림 자체를 막을 정도로 중요하게 다루지 않는다.
 */
export async function isAuctionHidden(auctionId) {
  try {
    const [rows] = await pool.query(
      'SELECT hidden_at FROM auctions WHERE id = ?',
      [auctionId],
    );
    return Boolean(rows[0]?.hidden_at);
  } catch (e) {
    console.error(`[worker] ${auctionId} hidden_at 조회 실패, 메일 발송 진행:`, e.message);
    return false;
  }
}

/**
 * 마감된 경매의 결과를 RDS 기록에서 뽑는다.
 *
 * 반환: { name, winner, losers } — 입찰이 없으면 winner 가 null(유찰).
 * 경매 자체가 없으면(관리자가 지웠는데 ZSET에 남은 경우) null.
 *
 * 한 사람이 여러 번 입찰했을 수 있으므로 사용자별 최고가로 접은 뒤 정렬한다.
 * 동점은 생기지 않지만(최소 증가액 1,000원), 만약을 대비해 먼저 부른 쪽이 이기게
 * created_at 을 2차 정렬 키로 둔다.
 */
export async function getAuctionOutcome(auctionId) {
  const [auctionRows] = await pool.query(
    'SELECT name FROM auctions WHERE id = ?',
    [auctionId],
  );
  if (!auctionRows[0]) return null;

  const [rows] = await pool.query(
    `SELECT b.user_id, u.email, u.nickname,
            MAX(b.price) AS price, MIN(b.created_at) AS first_bid_at
     FROM bids b JOIN users u ON u.id = b.user_id
     WHERE b.auction_id = ?
     GROUP BY b.user_id, u.email, u.nickname
     ORDER BY price DESC, first_bid_at ASC`,
    [auctionId],
  );

  const bidders = rows.map((r) => ({
    userId: r.user_id,
    email: r.email,
    nickname: r.nickname,
    price: Number(r.price),
  }));

  return {
    name: auctionRows[0].name,
    winner: bidders[0] ?? null,
    losers: bidders.slice(1),
  };
}

/**
 * 알림을 한 번에 넣는다.
 *
 * INSERT IGNORE 인 이유: 워커는 30초마다 돌고 메일 발송이 실패하면 같은 경매를
 * 다시 만날 수 있다. notifications 의 UNIQUE(user_id, auction_id, type) 와 짝을 이뤄
 * "같은 알림이 두 번 쌓이는" 일을 DB가 막게 한다 — 워커 쪽 중복 방지 로직이 필요 없다.
 */
export async function createNotifications(items) {
  if (!items.length) return 0;

  const rows = items.map((n) => [
    crypto.randomUUID(), n.userId, n.auctionId, n.type, n.message,
  ]);

  const [result] = await pool.query(
    `INSERT IGNORE INTO notifications (id, user_id, auction_id, type, message)
     VALUES ?`,
    [rows],
  );
  return result.affectedRows;
}
