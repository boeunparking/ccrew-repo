import { Router } from 'express';
import {
  listAuctions, getBidsForAuction, secondsLeft, isEnded,
  listNotifications, countUnreadNotifications, markNotificationsRead,
} from '../store.js';
import { requireAuth } from '../authMiddleware.js';

const router = Router();

// MyPage.jsx — 판매 탭
//
// includeHidden: 자동 검수에서 반려되어 비공개 처리된 내 경매도 판매자 본인에게는
// 보여야 한다 — 공개 목록/검색에서만 빠질 뿐, 왜 안 보이는지는 알 수 있어야 한다.
router.get('/sales', requireAuth, async (req, res) => {
  const auctions = await listAuctions({ includeHidden: true });
  const mySales = auctions.filter((a) => a.sellerId === req.user.sub);

  const items = [];
  for (const a of mySales) {
    let status = '진행중';
    let info;

    if (a.hiddenAt) {
      status = '반려됨';
      info = a.hiddenReason ?? '자동 검수에서 반려되었습니다';
    } else {
      const history = await getBidsForAuction(a.id);
      if (isEnded(a)) status = history.length > 0 ? '낙찰완료' : '유찰';
      info = status === '유찰' ? '-' :
        status === '낙찰완료' ? `낙찰가 ${a.currentPrice.toLocaleString()}원`
          : `현재가 ${a.currentPrice.toLocaleString()}원`;
    }

    items.push({ id: a.id, name: a.name, info, status });
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

// MyPage.jsx — 알림 탭 / Nav.jsx — 안 읽은 알림 뱃지
//
// unread 를 목록과 같이 내려서 뱃지가 따로 요청하지 않아도 되게 한다.
// 알림은 1인당 최대 50건만 조회하므로 한 번에 받아도 부담이 없다.
router.get('/notifications', requireAuth, async (req, res) => {
  const [items, unread] = await Promise.all([
    listNotifications(req.user.sub),
    countUnreadNotifications(req.user.sub),
  ]);
  res.json({ items, unread });
});

// 알림 탭을 열면 호출한다 — 안 읽은 알림을 전부 읽음으로 표시한다.
router.patch('/notifications/read', requireAuth, async (req, res) => {
  const updated = await markNotificationsRead(req.user.sub);
  res.json({ updated, unread: 0 });
});

export default router;
