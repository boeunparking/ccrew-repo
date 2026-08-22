import { Router } from 'express';
import { S3Client, DeleteObjectsCommand } from '@aws-sdk/client-s3';
import {
  listAuctions, countAllBids, claims, securityLogs, suspiciousBids, secondsLeft, isEnded,
  deleteAuction,
} from '../store.js';
import { requireAuth, requireAdmin } from '../authMiddleware.js';
import { connectionCount } from '../realtime.js';
import redis from '../valkey.js';

const UPLOAD_BUCKET = process.env.UPLOAD_BUCKET;
const s3 = new S3Client({ region: process.env.AWS_REGION || 'ap-northeast-2' });

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
/**
 * 경매 삭제 (관리자 전용).
 *
 * 입찰과 이미지까지 같이 사라지므로 되돌릴 수 없다. 라우터 전체에 걸린
 * requireAuth + requireAdmin 이 유일한 방어선이다.
 */
router.delete('/auctions/:id', async (req, res) => {
  const { id } = req.params;

  let result;
  try {
    result = await deleteAuction(id);
  } catch (err) {
    console.error('[admin] 경매 삭제 실패', id, err);
    return res.status(500).json({ error: '경매를 삭제하지 못했습니다' });
  }

  if (!result.deleted) {
    return res.status(404).json({ error: '존재하지 않는 경매입니다' });
  }

  // 입찰 잠금/현재가 캐시가 남아 있으면 같은 id 가 재사용될 때 옛 값이 살아난다.
  try {
    await redis.del(`auction:${id}:price`);
  } catch (err) {
    console.warn('[admin] Valkey 캐시 정리 실패 (무시)', id, err.message);
  }

  // S3 정리는 실패해도 삭제 자체를 되돌리지 않는다 — DB 는 이미 커밋됐고,
  // 여기서 500 을 내면 "삭제됐는데 실패했다고 뜨는" 더 혼란스러운 상태가 된다.
  // 남은 파일은 접근 경로가 없는 고아 객체일 뿐이라 로그만 남긴다.
  if (UPLOAD_BUCKET && result.imageKeys.length) {
    try {
      await s3.send(new DeleteObjectsCommand({
        Bucket: UPLOAD_BUCKET,
        Delete: { Objects: result.imageKeys.map((Key) => ({ Key })) },
      }));
    } catch (err) {
      console.warn('[admin] S3 이미지 정리 실패 (무시)', id, err.message);
    }
  }

  res.json({ id, deleted: true });
});

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
