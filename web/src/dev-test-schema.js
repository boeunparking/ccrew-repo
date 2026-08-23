// 로컬 개발용 스키마 자동생성 확인 스크립트. 프로덕션 코드에서 안 쓴다.
//
// server.js의 warmup이 부팅할 때마다 ensureSchema()를 부르므로, 이게 실패하면
// 컨테이너가 아예 안 뜬다. 그래서 "두 번 돌려도 멀쩡한가"를 여기서 확인한다.
//
// 실행 전 (PowerShell):
//   $env:DB_HOST='127.0.0.1'; $env:DB_PORT='3306'
//   $env:DB_USER='root'; $env:DB_PASSWORD='<로컬 비밀번호>'
//   $env:DB_NAME='cloud_duck_devtest'      # 기존 DB를 건드리지 않도록 별도 이름 권장
//   node src/dev-test-schema.js

import mysql from 'mysql2/promise';
import { ensureSchema } from './schema.js';

const DB_NAME = process.env.DB_NAME ?? 'cloud_duck';

const EXPECTED = ['users', 'auctions', 'auction_images', 'bids'];

async function main() {
  console.log(`[1] 첫 실행 — 데이터베이스와 테이블 생성 (${DB_NAME})`);
  await ensureSchema();

  console.log('[2] 재실행 — 이미 있는 상태에서 또 돌려본다 (부팅마다 일어나는 일)');
  await ensureSchema();

  const conn = await mysql.createConnection({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT ?? 3306),
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: DB_NAME,
  });

  const [tableRows] = await conn.query('SHOW TABLES');
  const tables = tableRows.map((t) => Object.values(t)[0]);
  const missing = EXPECTED.filter((t) => !tables.includes(t));
  console.log('[tables]', tables);
  if (missing.length) throw new Error(`빠진 테이블: ${missing.join(', ')}`);

  // 회원가입/로그인은 Cognito가 처리한다 — users.id는 Cognito sub를 그대로 담는
  // 프로필 사본일 뿐이라 email이 UNIQUE인지만 확인하면 충분하다.
  const [idx] = await conn.query('SHOW INDEX FROM users WHERE Column_name = ?', ['email']);
  console.log('[users.email UNIQUE]', idx.some((i) => i.Non_unique === 0) ? '있음 ✅' : '없음 ❌');
  if (!idx.some((i) => i.Non_unique === 0)) throw new Error('users.email UNIQUE 제약이 없다');

  await conn.end();
  console.log('\n✅ 스키마 자동생성 정상 — 재실행해도 안전하다');
}

main().catch((e) => {
  console.error('❌ 실패', e);
  process.exit(1);
});
