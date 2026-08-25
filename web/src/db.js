// RDS(MySQL) 커넥션 풀.
//
// 커넥션을 요청마다 새로 맺지 않고 풀에서 재사용한다 — ECS 태스크 하나가
// 여러 요청을 동시에 처리해도 매번 TCP 핸드셰이크를 다시 안 해도  되게.

import mysql from 'mysql2/promise';

const pool = mysql.createPool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT ?? 3306),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME ?? 'cloud_duck',

  waitForConnections: true,
  connectionLimit: 10,
  // rds/main.tf 가 db.t4g.micro(프리티어)라 커넥션 수를 너무 크게 잡으면
  // RDS 쪽 max_connections를 넘길 수 있다. 10이면 충분히 여유 있다.

  // DATETIME 컬럼에는 시간대가 저장되지 않는다. mysql2 는 그 값을 JS Date 로 바꿀 때
  // 이 옵션의 시간대로 해석하는데, 기본값 'local' 은 "컨테이너의 시간대"라서
  // TZ 환경변수 하나만 바뀌어도 모든 마감시간이 조용히 몇 시간씩 밀린다.
  // 우리는 항상 UTC 로 넣고 UTC 로 읽는다 — 'Z' 로 못박아 그 사고를 막는다.
  // (지금까지도 컨테이너가 UTC 였으므로 기존 데이터의 해석은 달라지지 않는다.)
  timezone: 'Z',
});

export default pool;
