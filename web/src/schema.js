/**
 * 부팅할 때 데이터베이스와 테이블이 있는지 확인하고, 없으면 만든다.
 *
 * 왜 앱이 이걸 하나:
 *   RDS는 데이터베이스를 만들어주지 않고(모듈에 db_name 설정이 없다), db.js의 풀은
 *   `database: cloud_duck` 으로 접속한다. 즉 누군가 CREATE DATABASE를 해주기 전까지
 *   커넥션 자체가 안 맺어진다. 그걸 사람이 VPN 붙어서 하는 대신 앱이 스스로 한다.
 *
 * db.js의 풀을 못 쓰는 이유도 같다 — 그 풀은 아직 없을 수도 있는 데이터베이스를
 * 지정해서 접속하므로, 여기서는 데이터베이스 없이 붙는 커넥션을 따로 만든다.
 *
 * 주의: 이건 "스키마 생성"이지 "스키마 변경"이 아니다. CREATE TABLE IF NOT EXISTS는
 * 이미 있는 테이블을 건드리지 않으므로, 운영 중인 DB의 컬럼을 바꾸려면
 * db/migrations/ 에 ALTER 문을 따로 써야 한다.
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import mysql from 'mysql2/promise';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SCHEMA_SQL = fs.readFileSync(path.join(__dirname, 'schema.sql'), 'utf8');

const DB_NAME = process.env.DB_NAME ?? 'cloud_duck';

export async function ensureSchema() {
  const conn = await mysql.createConnection({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT ?? 3306),
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    // schema.sql을 문장 단위로 쪼개지 않고 통째로 넘기기 위해 켠다.
    // 이 커넥션은 부팅 때 우리가 만든 SQL만 실행하고 바로 닫는다 —
    // 사용자 입력이 닿는 경로가 아니므로 여기서만 켜도 안전하다.
    multipleStatements: true,
  });

  try {
    // 데이터베이스 이름은 환경변수라 바인딩 파라미터를 못 쓴다(식별자 위치).
    // 배포 설정에서 오는 값이지 사용자 입력이 아니고, 백틱으로 감싼다.
    await conn.query(
      `CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
       CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci`,
    );
    // changeUser는 재인증까지 하므로 여기서는 USE로 충분하다.
    await conn.query(`USE \`${DB_NAME}\``);
    await conn.query(SCHEMA_SQL);
  } finally {
    await conn.end();
  }
}
