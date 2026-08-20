// 로컬 개발용 동시입찰 검증 스크립트. 프로덕션 코드에서 안 쓴다.
//
// 실행 전:
//   VALKEY_HOST=localhost VALKEY_PORT=6379 VALKEY_TLS=false node src/dev-test-bid.js
//
// 하는 일:
//   1. 가짜 경매 하나를 만들고 시작가를 심는다.
//   2. 똑같은 입찰가로 "동시에" 10번 입찰을 쏜다 (진짜 동시 요청 흉내).
//   3. 몇 개가 성공(accepted)했는지 센다. 원자성이 지켜졌다면 반드시 1개만 성공해야 한다.

import redis, { initAuctionPrice, attemptBid } from './valkey.js';

const AUCTION_ID = `test-${Date.now()}`;
const START_PRICE = 10000;
const SAME_BID = 11000; // 최소 증가액(1000) 딱 채운 같은 가격으로 여러 명이 동시에 부른다고 가정

async function main() {
  console.log(`[setup] auction=${AUCTION_ID} start=${START_PRICE}`);
  await initAuctionPrice(AUCTION_ID, START_PRICE);

  console.log(`[fire] ${SAME_BID}원으로 10개 동시 입찰...`);
  const results = await Promise.all(
    Array.from({ length: 10 }, (_, i) => attemptBid(AUCTION_ID, SAME_BID).then((r) => ({ i, ...r }))),
  );

  const winners = results.filter((r) => r.accepted);
  console.log('[result]', results);
  console.log(`\n성공한 입찰 수: ${winners.length}개 (기대값: 1개)`);
  console.log(winners.length === 1 ? '✅ 원자성 정상 동작' : '❌ 문제 있음 — race condition 발생');

  await redis.quit();
  process.exit(winners.length === 1 ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
