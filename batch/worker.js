import { getRedisClient } from './src/redisClient.js';
import { notifyEndedAuctions, updatePopularStats } from './src/jobs.js';

const POLL_INTERVAL_MS = (Number(process.env.POLL_INTERVAL_SECONDS) || 30) * 1000;

let stopping = false;
let running = false;

async function tick() {
  if (running) return; // 이전 틱이 아직 안 끝났으면 겹쳐 돌리지 않는다
  running = true;
  try {
    const redis = await getRedisClient();
    if (!redis) {
      console.warn('[worker] REDIS_URL 없음 — 이번 틱 건너뜀');
      return;
    }
    await notifyEndedAuctions(redis);
    await updatePopularStats(redis);
  } catch (e) {
    console.error('[worker] tick 실패:', e);
  } finally {
    running = false;
  }
}

console.log(`[worker] 시작. ${POLL_INTERVAL_MS / 1000}초마다 낙찰 알림 + 인기 상품 통계를 갱신합니다`);

const interval = setInterval(tick, POLL_INTERVAL_MS);
tick(); // 뜨자마자 한 번 바로 실행 (다음 틱까지 기다리지 않음)

function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  console.log(`[worker] ${signal} 수신, 종료합니다`);
  clearInterval(interval);
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
