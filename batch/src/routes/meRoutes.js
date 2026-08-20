import { Router } from 'express';
import { listAuctions, getBidsForAuction, notifications, secondsLeft, isEnded } from '../store.js';
import { requireAuth } from '../authMiddleware.js';

const router = Router();

// MyPage.jsx — 판매 탭
router.get('/sales', requireAuth, async (req, res) => {
  const auctions = await listAuctions();
  const mySales = auctions.filter((a) => a.sellerId === req.user.sub);

  const items = [];
  for (const a of mySales) {
    const history = await getBidsForAuction(a.id);
    let status = '진행중';
    if (isEnded(a)) status = history.length > 0 ? '낙찰완료' : '유찰';

    items.push({
      id: a.id,
      name: a.name,
      info: status === '유찰' ? '-' :
        status === '낙찰완료' ? `낙찰가 ${a.currentPrice.toLocaleString()}원`
          : `현재가 ${a.currentPrice.toLocaleString()}원`,
      status,
    });
  }

  res.json({ items });
});

// MyPage.jsx — 구매 탭
router.get('/purchases', requireAuth, async (req, res) => {
  const auctions = await listAuctions();
  const items = [];

  for (const a of auctions) {
    const history = await getBidsForAuction(a.id);
    const mine = history.filter((b) => b.userId === req.user.sub);
    if (mine.length === 0) continue;

    const myBid = Math.max(...mine.map((b) => b.price));
    let status = a.currentPrice <= myBid ? '최고가' : '경쟁중';
    if (isEnded(a)) status = a.currentPrice <= myBid ? '낙찰' : '패찰';

    items.push({
      id: a.id,
      name: a.name,
      info: `내 입찰가 ${myBid.toLocaleString()}원`,
      status,
      secondsLeft: secondsLeft(a),
    });
  }

  res.json({ items });
});

// MyPage.jsx — 알림 탭
router.get('/notifications', requireAuth, (_req, res) => {
  res.json({ items: notifications });
});

export default router;
