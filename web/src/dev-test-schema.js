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

const EXPECTED = ['users', 'user_identities', 'auctions', 'auction_images', 'bids'];

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

  // 소셜 전용 계정은 비밀번호가 없다 — NULL이 들어가야 한다
  const [cols] = await conn.query('SHOW COLUMNS FROM users LIKE ?', ['password_hash']);
  console.log('[users.password_hash]', cols[0].Null === 'YES' ? 'NULL 허용 ✅' : `NOT NULL ❌`);
  if (cols[0].Null !== 'YES') throw new Error('password_hash가 NOT NULL이면 소셜 가입이 실패한다');

  // 같은 소셜 계정이 우리 계정 두 개에 붙는 걸 막는 제약
  const [idx] = await conn.query('SHOW INDEX FROM user_identities');
  const uniques = [...new Set(idx.filter((i) => i.Non_unique === 0).map((i) => i.Key_name))];
  console.log('[user_identities UNIQUE]', uniques);
  for (const key of ['uq_identity', 'uq_user_provider']) {
    if (!uniques.includes(key)) throw new Error(`${key} 제약이 없다`);
  }

  await conn.end();
  console.log('\n✅ 스키마 자동생성 정상 — 재실행해도 안전하다');
}

main().catch((e) => {
  console.error('❌ 실패', e);
  process.exit(1);
});
