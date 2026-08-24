import http from 'http';

import { createApp, state } from './src/app.js';
import { attachRealtime } from './src/realtime.js';
import { ensureSchema } from './src/schema.js';
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
  // 데이터베이스/테이블이 없으면 만든다. pool.query보다 반드시 먼저 와야 한다 —
  // db.js의 풀은 cloud_duck 데이터베이스를 지정해서 접속하므로, 그게 없으면
  // SELECT 1조차 커넥션 단계에서 실패한다.
  //
  // 도쿄(rds_tokyo_replica)는 읽기 전용이라 여기서 실패한다. 하지만 replica는
  // 서울의 스키마를 복제로 받으므로 만들 필요 자체가 없다 — 경고만 남기고 넘어간다.
  try {
    await ensureSchema();
    console.log('[init] 스키마 확인 완료');
  } catch (e) {
    console.warn('[init] 스키마 생성 건너뜀 (읽기 전용 DB일 수 있음) —', e.message);
  }

  // RDS가 아직 안 떠 있으면 여기서 대기하게 된다 — /health가 계속 503을 반환해
  // ALB가 이 태스크로 트래픽을 안 보내므로 안전하다.
  await pool.query('SELECT 1');

  // 관리자 계정은 더 이상 여기서 시드하지 않는다 — Cognito User Pool의 admin 그룹이
  // 관리자 여부의 source of truth다. 최초 admin 계정은 terraform이 apply 시점에
  // aws_cognito_user(+aws_cognito_user_in_group)로 만든다(terraform/admin-credentials.tf).

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
