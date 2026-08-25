import { Router } from 'express';
import { S3Client, DeleteObjectsCommand } from '@aws-sdk/client-s3';
import {
  listAuctions, countAllBids, claims, securityLogs, suspiciousBids, secondsLeft, isEnded,
  deleteAuction, listHiddenAuctions, restoreAuction, getAuctionById, getBidsForAuction,
} from '../store.js';
import { requireAuth, requireAdmin } from '../authMiddleware.js';
import { connectionCount } from '../realtime.js';
import redis, { getBidPrice, resyncAuctionPrice } from '../valkey.js';

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

/**
 * 특정 경매의 "입찰이 안 된다" 증상 진단.
 *
 * 입찰 판정은 Valkey(auction:{id}:price)가, 화면의 현재가 표시는 RDS가 담당한다.
 * 이 둘이 어긋나면 화면이 계산한 최소 입찰가가 판정 기준에 늘 못 미쳐서
 * 그 경매만 400(현재가보다 1,000원 이상...)이 반복된다 — 여기서 바로 확인된다.
 */
router.get('/auctions/:id/price', async (req, res) => {
  const { id } = req.params;

  const auction = await getAuctionById(id, { includeHidden: true });
  if (!auction) return res.status(404).json({ error: '존재하지 않는 경매입니다' });

  const [valkeyPrice, history] = await Promise.all([
    getBidPrice(id).catch(() => null),
    getBidsForAuction(id),
  ]);
  const highestBid = history.length ? Math.max(...history.map((b) => b.price)) : null;

  res.json({
    id,
    name: auction.name,
    rdsCurrentPrice: auction.currentPrice,
    valkeyPrice, // null이면 키가 사라진 것 — 이제 첫 입찰 때 RDS 값으로 자동 복구된다
    highestBid,
    // 셋이 같아야 정상. valkeyPrice가 더 크면 입찰이 막힌 상태다.
    inSync: valkeyPrice !== null && valkeyPrice === auction.currentPrice,
    hidden: Boolean(auction.hiddenAt),
    ended: isEnded(auction),
  });
});

/**
 * 어긋난 Valkey 현재가를 RDS의 기록(실제 남아 있는 최고 입찰가)에 맞춰 되돌린다.
 *
 * 가격을 낮추는 방향이라 진행 중인 입찰을 덮어쓸 수 있으므로 자동으로 돌지 않는다.
 * 위 진단으로 inSync=false를 확인한 뒤에만 쓴다.
 */
router.post('/auctions/:id/price/resync', async (req, res) => {
  const { id } = req.params;

  const auction = await getAuctionById(id, { includeHidden: true });
  if (!auction) return res.status(404).json({ error: '존재하지 않는 경매입니다' });

  const history = await getBidsForAuction(id);
  // 기록으로 증명되는 값만 기준으로 삼는다. 입찰이 없으면 시작가로 되돌아간다.
  const truth = history.length
    ? Math.max(auction.currentPrice, ...history.map((b) => b.price))
    : auction.currentPrice;

  const before = await getBidPrice(id).catch(() => null);
  await resyncAuctionPrice(id, truth);

  console.warn(`[admin] 현재가 재동기화 ${id}: valkey ${before} → ${truth}`);
  res.json({ id, before, after: truth });
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

// 반려 큐 — image_moderation Lambda가 REJECTED로 판정해 자동 비공개된 경매들.
router.get('/moderation', async (_req, res) => {
  const items = await listHiddenAuctions();
  res.json({ items });
});

// 관리자가 검토 후 오탐(false positive)이라고 판단하면 다시 공개한다.
router.patch('/moderation/:id/restore', async (req, res) => {
  const restored = await restoreAuction(req.params.id);
  if (!restored) return res.status(404).json({ error: '비공개 처리된 경매가 아닙니다' });
  res.json({ id: req.params.id, hidden: false });
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
