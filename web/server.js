import http from 'http';
import bcrypt from 'bcryptjs';
import crypto from 'crypto';

import { createApp, state } from './src/app.js';
import { attachRealtime } from './src/realtime.js';
import { upsertUser } from './src/store.js';
import pool from './src/db.js';

const PORT = process.env.PORT || 3000;

const app = createApp();
const server = http.createServer(app);
attachRealtime(server);

/**
 * 워밍업. 여기서 DB 커넥션 풀과 Redis 연결을 만든 뒤에야
 * /health가 200을 반환하게 한다.
 * 그러면 ALB가 아직 준비 안 된 태스크로는 트래픽을 보내지 않는다.
 */
async function warmup() {
  // RDS가 아직 안 떠 있으면 여기서 대기하게 된다 — /health가 계속 503을 반환해
  // ALB가 이 태스크로 트래픽을 안 보내므로 안전하다.
  await pool.query('SELECT 1');

  // 데모용 관리자 계정. 실제 배포에서는 반드시 지우거나 시드 스크립트로 분리할 것.
  // upsert라서 재배포마다 다시 만들어도 에러 나지 않는다.
  //
  // 도쿄(rds_tokyo_replica)는 읽기 전용 크로스 리전 replica라 이 쓰기 자체가 항상 실패한다.
  // 그래도 서버가 죽으면 안 된다 — 도쿄는 원래 읽기 트래픽만 받는 웜 스탠바이라, admin
  // 계정 시드 실패 정도로 부팅 자체를 막을 이유가 없다. DB 연결 확인(SELECT 1)은 위에서
  // 이미 통과했으니, 여기서부터는 실패해도 경고만 남기고 넘어간다.
  try {
    const email = process.env.ADMIN_EMAIL || 'admin@cloudduck.cloud';
    const password = process.env.ADMIN_PASSWORD || 'admin1234';
    await upsertUser({
      id: crypto.randomUUID(),
      email,
      passwordHash: await bcrypt.hash(password, 10),
      nickname: 'admin',
      role: 'admin',
    });
  } catch (e) {
    console.warn('[init] admin 계정 시드 실패 (읽기 전용 DB일 수 있음) — 무시하고 계속 진행', e.message);
  }

  state.ready = true;
  console.log('[init] warmup 완료, 트래픽 수신 시작');
}

// 컨테이너 밖에서 접근하려면 반드시 0.0.0.0
server.listen(PORT, '0.0.0.0', () => {
  console.log(`[boot] listening on 0.0.0.0:${PORT}`);
  warmup().catch((e) => {
    console.error('[init] warmup 실패', e);
    process.exit(1);
  });
});

// Fargate가 태스크를 내릴 때 SIGTERM을 보낸다.
// ready를 먼저 내려서 ALB가 새 요청을 안 보내게 한 뒤 종료한다.
function shutdown(signal) {
  console.log(`[shutdown] ${signal} 수신`);
  state.ready = false;
  setTimeout(() => {
    server.close(() => process.exit(0));
  }, 3000);
  setTimeout(() => process.exit(1), 15000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
