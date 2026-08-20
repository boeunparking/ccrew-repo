import { Router } from 'express';
import {
  listAuctions, countAllBids, claims, securityLogs, suspiciousBids, secondsLeft, isEnded,
} from '../store.js';
import { requireAuth, requireAdmin } from '../authMiddleware.js';
import { connectionCount } from '../realtime.js';
import redis from '../valkey.js';

const router = Router();

// 이 라우터 전체가 관리자 전용
router.use(requireAuth, requireAdmin);

// AdminDashboard.jsx 상단 통계 3종
router.get('/stats', async (_req, res) => {
  res.json({
    bidCount: await countAllBids(),
    // 시뮬레이션이 아니라 실제 WebSocket 연결 수
    activeUsers: connectionCount(),
    suspiciousCount: suspiciousBids.length,
  });
});

// 실시간 경매 리스트
router.get('/auctions', async (_req, res) => {
  const auctions = await listAuctions();
  const items = auctions
    .filter((a) => !isEnded(a))
    .sort((a, b) => secondsLeft(a) - secondsLeft(b))
    .map((a) => ({
      id: a.id,
      name: a.name,
      price: a.currentPrice,
      secondsLeft: secondsLeft(a),
    }));

  res.json({ items });
});

// 인기 상품 통계 — worker(batch)가 주기적으로(POLL_INTERVAL_SECONDS) 미리 구워둔 스냅샷을
// 그대로 읽기만 한다. 여기서 직접 집계하지 않는 이유: 실시간성이 필요 없는 통계라서
// 요청마다 계산하기보단 Fargate Spot 워커가 비동기로 미리 만들어두는 게 더 싸다.
router.get('/stats/popular', async (_req, res) => {
  const raw = await redis.get('stats:popular:snapshot');
  res.json(raw ? JSON.parse(raw) : { items: [], updatedAt: null });
});

router.get('/suspicious', (_req, res) => res.json({ items: suspiciousBids }));
router.get('/logs', (_req, res) => res.json({ items: securityLogs }));
router.get('/claims', (_req, res) => res.json({ items: claims }));

// 클레임 처리 상태 진행: 대기 → 처리중 → 완료
router.patch('/claims/:id', (req, res) => {
  const claim = claims.find((c) => c.id === req.params.id);
  if (!claim) return res.status(404).json({ error: '존재하지 않는 클레임입니다' });

  const order = ['대기', '처리중', '완료'];
  const next = req.body?.status;

  if (next && order.includes(next)) {
    claim.status = next;
  } else {
    claim.status = order[Math.min(order.indexOf(claim.status) + 1, order.length - 1)];
  }

  res.json(claim);
});

export default router;
