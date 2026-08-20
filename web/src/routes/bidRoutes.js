import { Router } from 'express';
import crypto from 'crypto';
import { auctions, bids, secondsLeft, isEnded } from '../store.js';
import { requireAuth } from '../authMiddleware.js';
import { broadcast } from '../realtime.js';
import { getRedisClient } from '../redisClient.js';

const router = Router();

const MIN_INCREMENT = 1000;

/**
 * 입찰가 갱신(현재가 조회 + 최소증분 검증 + 갱신)을 Valkey Lua 스크립트로 원자적으로 처리한다.
 *
 * 프로세스 내 락(예: Map 뮤텍스)은 "그 컨테이너 안에서만" 유효하다. ECS 태스크가
 * 2개 이상 뜬 상태에서 같은 경매에 거의 동시에 입찰이 들어오면, 서로 다른 태스크는
 * 서로의 락을 모르기 때문에 둘 다 통과해버릴 수 있다 — 마감 직전 순간에 이게 터지면
 * 낮은 입찰가가 최종가로 남는 금전 분쟁으로 직결된다.
 * Valkey는 모든 태스크가 공유하는 단일 지점이고, Redis(-호환) 서버는 명령을 순차
 * 실행하므로 EVAL 하나 안에 "조회+검증+갱신"을 다 넣으면 태스크 개수와 무관하게
 * 레이스 컨디션이 생길 수 없다.
 */
const BID_SCRIPT = `
local minimum = tonumber(redis.call('GET', KEYS[1])) + tonumber(ARGV[2])
if tonumber(ARGV[1]) < minimum then
  return {tonumber(redis.call('GET', KEYS[1])), minimum, 0}
end
redis.call('SET', KEYS[1], ARGV[1])
return {tonumber(ARGV[1]), minimum, 1}
`;

/** REDIS_URL 없는 로컬 개발 전용 폴백. 다중 태스크 환경에서는 절대 이 경로를 타면 안 된다. */
function localCompareAndSet(currentPrice, price) {
  const minimum = currentPrice + MIN_INCREMENT;
  if (price < minimum) return { current: currentPrice, minimum, success: false };
  return { current: price, minimum, success: true };
}

async function tryPlaceBid(auctionId, price, fallbackCurrentPrice) {
  const redis = await getRedisClient();
  if (!redis) {
    console.warn('[bid] REDIS_URL 없음 — 로컬 폴백 사용 (다중 태스크 환경 금지)');
    return localCompareAndSet(fallbackCurrentPrice, price);
  }

  const key = `auction:${auctionId}:price`;
  // 이 경매 가격을 Valkey에서 처음 다루는 순간이면 지금 값으로 시드한다.
  // NX라서 다른 태스크가 이미 시드했으면 무시된다.
  await redis.set(key, String(fallbackCurrentPrice), { NX: true });

  const [current, minimum, success] = await redis.eval(BID_SCRIPT, {
    keys: [key],
    arguments: [String(price), String(MIN_INCREMENT)],
  });

  return { current, minimum, success: success === 1 };
}

// POST /auctions/:id/bids  { price }
router.post('/auctions/:id/bids', requireAuth, async (req, res) => {
  const auctionId = req.params.id;
  const price = Number(req.body?.price);

  if (!Number.isFinite(price)) {
    return res.status(400).json({ error: '입찰가를 숫자로 입력해 주세요' });
  }

  const auction = auctions.get(auctionId);
  if (!auction) {
    return res.status(404).json({ error: '존재하지 않는 경매입니다' });
  }
  if (isEnded(auction)) {
    return res.status(409).json({ error: '이미 마감된 경매입니다' });
  }
  // 본인 상품 입찰 차단 (AdminDashboard의 이상 입찰 항목과 같은 규칙)
  if (auction.sellerId && auction.sellerId === req.user.sub) {
    return res.status(403).json({ error: '본인이 등록한 상품에는 입찰할 수 없습니다' });
  }

  const { current, minimum, success } = await tryPlaceBid(auctionId, price, auction.currentPrice);

  if (!success) {
    return res.status(400).json({
      error: `현재가보다 ${MIN_INCREMENT.toLocaleString()}원 이상 높게 입찰해 주세요`,
      minimum,
    });
  }

  const bid = {
    id: crypto.randomUUID(),
    userId: req.user.sub,
    nickname: req.user.nickname,
    price: current,
    createdAt: new Date().toISOString(),
  };

  // Valkey가 승인한 값으로 이 태스크의 표시값도 맞춘다.
  auction.currentPrice = current;
  bids.get(auctionId).unshift(bid);

  // 낙찰 알림/인기 상품 통계 워커(batch)가 쓸 상태 갱신.
  // 여기서 실패해도 입찰 자체는 이미 성공했으니 응답을 막지 않는다.
  const redis = await getRedisClient();
  if (redis) {
    await Promise.all([
      redis.hSet(`auction:${auctionId}:leader`, {
        userId: bid.userId,
        nickname: bid.nickname,
        email: req.user.email,
        price: String(bid.price),
      }),
      redis.zIncrBy('auction:popularity', 1, auctionId),
    ]).catch((e) => console.error('[bid] 워커용 상태 갱신 실패:', e.message));
  }

  // 같은 경매를 보고 있는 모든 브라우저에 밀어준다 (Redis pub/sub로 모든 태스크에 퍼짐)
  broadcast(auctionId, {
    type: 'BID_PLACED',
    auctionId,
    currentPrice: auction.currentPrice,
    bidder: bid.nickname,
    secondsLeft: secondsLeft(auction),
    at: bid.createdAt,
  });

  res.status(201).json({
    currentPrice: auction.currentPrice,
    bid: { user: bid.nickname, price: bid.price, at: bid.createdAt },
  });
});

// GET /auctions/:id/bids
router.get('/auctions/:id/bids', (req, res) => {
  if (!auctions.has(req.params.id)) {
    return res.status(404).json({ error: '존재하지 않는 경매입니다' });
  }
  const history = bids.get(req.params.id) ?? [];
  res.json({
    items: history.map((b) => ({ user: b.nickname, price: b.price, at: b.createdAt })),
  });
});

// BidHistory.jsx — 내가 참여 중인 경매 목록
router.get('/bids/me', requireAuth, (req, res) => {
  const items = [];

  for (const auction of auctions.values()) {
    const mine = (bids.get(auction.id) ?? []).filter((b) => b.userId === req.user.sub);
    if (mine.length === 0) continue;

    const myBid = Math.max(...mine.map((b) => b.price));
    items.push({
      id: auction.id,
      name: auction.name,
      seller: auction.seller,
      myBid,
      price: auction.currentPrice,
      secondsLeft: secondsLeft(auction),
      ended: isEnded(auction),
    });
  }

  items.sort((a, b) => a.secondsLeft - b.secondsLeft);

  res.json({
    items,
    summary: {
      total: items.length,
      leading: items.filter((i) => !i.ended && i.price <= i.myBid).length,
      competing: items.filter((i) => !i.ended && i.price > i.myBid).length,
      closingSoon: items.filter((i) => !i.ended && i.secondsLeft <= 600).length,
    },
  });
});

export default router;
