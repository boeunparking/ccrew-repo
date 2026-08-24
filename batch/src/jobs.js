import { sendWinnerEmail } from './ses.js';
import { isAuctionHidden } from './db.js';

const OPEN_AUCTIONS_KEY = 'auctions:open'; // ZSET: auctionId -> endsAt(ms)  (web이 경매 생성 시 ZADD)
const POPULARITY_KEY = 'auction:popularity'; // ZSET: auctionId -> 입찰 횟수 (web이 입찰마다 ZINCRBY)
const POPULAR_SNAPSHOT_KEY = 'stats:popular:snapshot'; // 관리자 API(GET /admin/stats/popular)가 읽는 캐시

/**
 * 마감된 경매를 찾아 낙찰자에게 메일을 보낸다.
 *
 * 워커가 여러 대(desired_count>1) 떠 있어도 안전하다: ZREM은 원자적이라 같은
 * auctionId를 두 워커가 동시에 뽑아도 딱 하나만 1(성공)을 받고 나머지는 0을
 * 받는다 — 0을 받은 쪽은 이미 다른 워커가 처리 중이라는 뜻이므로 건너뛴다.
 */
export async function notifyEndedAuctions(redis) {
  const endedIds = await redis.zRangeByScore(OPEN_AUCTIONS_KEY, 0, Date.now());

  for (const auctionId of endedIds) {
    const claimed = await redis.zRem(OPEN_AUCTIONS_KEY, auctionId);
    if (claimed === 0) continue; // 다른 워커가 이미 처리함

    const [leader, meta] = await Promise.all([
      redis.hGetAll(`auction:${auctionId}:leader`),
      redis.hGetAll(`auction:${auctionId}:meta`),
    ]);

    if (!leader?.email) {
      console.log(`[worker] ${auctionId} 유찰 (입찰자 없음) — 메일 없음`);
      continue;
    }

    // web/Lambda가 이미지 반려 시 RDS에만 hidden_at을 남기고 이 ZSET은 안 건드리므로,
    // 여기서 직접 한 번 더 확인한다 — 안 하면 반려된 경매도 그대로 낙찰 메일이 나간다.
    if (await isAuctionHidden(auctionId)) {
      console.log(`[worker] ${auctionId} 반려(hidden)된 경매 — 낙찰 메일 건너뜀`);
      continue;
    }

    try {
      await sendWinnerEmail({
        to: leader.email,
        auctionName: meta?.name || auctionId,
        price: Number(leader.price),
      });
      console.log(`[worker] ${auctionId} 낙찰 메일 발송 완료 → ${leader.email}`);
    } catch (e) {
      console.error(`[worker] ${auctionId} 메일 발송 실패:`, e.message);
    }
  }
}

/**
 * 입찰 횟수 기준 인기 상품 Top 10을 계산해서 스냅샷으로 저장한다.
 * 매 요청마다 계산하지 않고 워커가 주기적으로 미리 구워두는 이유:
 * 실시간성이 필요 없는 통계라서(원래 설계 문서의 "비동기 배치" 항목).
 */
export async function updatePopularStats(redis) {
  const top = await redis.zRangeWithScores(POPULARITY_KEY, 0, 9, { REV: true });

  const items = await Promise.all(
    top.map(async ({ value: auctionId, score }) => {
      const meta = await redis.hGetAll(`auction:${auctionId}:meta`);
      return { auctionId, name: meta?.name || auctionId, bidCount: score };
    })
  );

  await redis.set(POPULAR_SNAPSHOT_KEY, JSON.stringify({ items, updatedAt: new Date().toISOString() }));
}
