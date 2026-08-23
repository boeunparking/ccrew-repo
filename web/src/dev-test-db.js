// 로컬 개발용 DB 연결 확인 스크립트. 프로덕션 코드에서 안 쓴다.
//
// 실행 전:
//   DB_HOST=localhost DB_PORT=3307 DB_USER=root DB_PASSWORD=localtest1234 DB_NAME=cloud_duck node src/dev-test-db.js

import pool from './db.js';

async function main() {
  const [pingRows] = await pool.query('SELECT 1 + 1 AS result');
  console.log('[ping]', pingRows[0]);

  const [tables] = await pool.query('SHOW TABLES');
  console.log('[tables]', tables.map((t) => Object.values(t)[0]));

  // 간단히 users에 한 명 넣고 다시 읽어본다 (Cognito sub 대신 UUID로 대체)
  const testEmail = `dev-test-${Date.now()}@example.com`;
  await pool.query(
    'INSERT INTO users (id, email, nickname) VALUES (UUID(), ?, ?)',
    [testEmail, 'devtester'],
  );
  const [rows] = await pool.query('SELECT id, email, nickname FROM users WHERE email = ?', [testEmail]);
  console.log('[insert+select]', rows[0]);

  await pool.end();
  console.log('\n✅ DB 연결/쿼리 정상 동작');
}

main().catch((e) => {
  console.error('❌ 실패', e);
  process.exit(1);
});
