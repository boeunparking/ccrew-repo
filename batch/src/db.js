// RDS(MySQL) 커넥션 풀.
//
// batch는 원래 Redis만 보는 워커지만, 이미지 반려(hidden_at) 상태는 RDS에만
// 존재한다(web/src/store.js). 낙찰 메일을 보내기 직전에 이 상태를 확인해서
// 반려된 경매의 낙찰 메일이 나가지 않게 하려고 최소한으로 연결한다.

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
