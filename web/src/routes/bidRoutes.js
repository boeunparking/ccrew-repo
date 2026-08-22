import { Router } from 'express';
import crypto from 'crypto';
import {
  getAuctionById,
  listAuctions,
  createBid,
  updateAuctionCurrentPrice,
  getBidsForAuction,
  secondsLeft,
  isEnded,
  CLOSING_SOON_SECONDS,
} from '../store.js';
import { requireAuth } from '../authMiddleware.js';
import { broadcast } from '../realtime.js';
import redis, { attemptBid } from '../valkey.js';

const router = Router();

const MIN_INCREMENT = 1000;

// POST /auctions/:id/bids  { price }
//
// 현재가 갱신의 원자성은 이 프로세스 안의 락이 아니라 Valkey에서 실행되는
// bid.lua 스크립트가 보장한다 (attemptBid). ECS 태스크가 여러 개여도 모든
// 태스크가 같은 Valkey를 보므로 레이스 컨디션이 생길 수 없다.
router.post('/auctions/:id/bids', requireAuth, async (req, res) => {
  const auctionId = req.params.id;
  const price = Number(req.body?.price);

  if (!Number.isFinite(price)) {
    return res.status(400).json({ error: '입찰가를 숫자로 입력해 주세요' });
  }

  const auction = await getAuctionById(auctionId);
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

  try {
    const { accepted, currentPrice } = await attemptBid(auctionId, price);

    if (!accepted) {
      return res.status(400).json({
        error: `현재가보다 ${MIN_INCREMENT.toLocaleString()}원 이상 높게 입찰해 주세요`,
        minimum: currentPrice + MIN_INCREMENT,
      });
    }

    const bid = {
      id: crypto.randomUUID(),
      auctionId,
      userId: req.user.sub,
      nickname: req.user.nickname,
      price: currentPrice,
      createdAt: new Date().toISOString(),
    };

    // Valkey가 승인한 값(currentPrice)을 RDS에도 반영해 둘을 동기화한다.
    await createBid(bid);
    await updateAuctionCurrentPrice(auctionId, currentPrice);

    // 낙찰 알림/인기 상품 통계 워커(batch)가 쓸 상태 갱신.
    // 여기서 실패해도 입찰 자체는 이미 성공했으니 응답을 막지 않는다.
    await Promise.all([
      redis.hset(`auction:${auctionId}:leader`,
        'userId', bid.userId,
        'nickname', bid.nickname,
        'email', req.user.email,
        'price', String(bid.price),
      ),
      redis.zincrby('auction:popularity', 1, auctionId),
    ]).catch((e) => console.error('[bid] 워커용 상태 갱신 실패:', e.message));

    // 같은 경매를 보고 있는 모든 브라우저에 밀어준다
    broadcast(auctionId, {
      type: 'BID_PLACED',
      auctionId,
      currentPrice,
      bidder: bid.nickname,
      secondsLeft: secondsLeft(auction),
      at: bid.createdAt,
    });

    res.status(201).json({
      currentPrice,
      bid: { user: bid.nickname, price: bid.price, at: bid.createdAt },
    });
  } catch (e) {
    res.status(e.status ?? 500).json({ error: e.message ?? '입찰 처리 중 오류가 발생했습니다' });
  }
});

// GET /auctions/:id/bids
router.get('/auctions/:id/bids', async (req, res) => {
  const auction = await getAuctionById(req.params.id);
  if (!auction) {
    return res.status(404).json({ error: '존재하지 않는 경매입니다' });
  }
  const history = await getBidsForAuction(req.params.id);
  res.json({
    items: history.map((b) => ({ user: b.nickname, price: b.price, at: b.createdAt })),
  });
});

// BidHistory.jsx — 내가 참여 중인 경매 목록
router.get('/bids/me', requireAuth, async (req, res) => {
  const auctions = await listAuctions();
  const items = [];

  for (const auction of auctions) {
    const history = await getBidsForAuction(auction.id);
    const mine = history.filter((b) => b.userId === req.user.sub);
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
      // 목록의 "마감임박" 필터와 같은 기준을 써야 사용자가 보는 숫자가 어긋나지 않는다.
      closingSoon: items.filter((i) => !i.ended && i.secondsLeft <= CLOSING_SOON_SECONDS).length,
    },
  });
});

export default router;
