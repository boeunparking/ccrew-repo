// Valkey(Redis) 연결 + 입찰 처리 도우미
//
// bid.lua 스크립트를 읽어서 EVAL로 실행시키는 역할만 한다.
// 실제 DB(RDS) 저장은 여기서 하지 않는다 — 이건 "현재가 race condition만" 막는 담당.

import Redis from 'ioredis';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BID_SCRIPT = fs.readFileSync(path.join(__dirname, 'lua', 'bid.lua'), 'utf8');

const MIN_INCREMENT = 1000; // bidRoutes.js와 동일한 값 — 나중에 하나로 합쳐야 함

// REDIS_URL 스킴으로 TLS 여부가 결정된다 (rediss:// = TLS 켜짐, redis:// = 꺼짐).
// compute.tf가 실제로 이 이름(REDIS_URL)으로 rediss://... 를 주입한다 — batch(워커)의
// redisClient.js와 환경변수 이름을 통일해서, 배포 설정을 한 가지 관례로 맞췄다.
// 로컬 docker valkey는 TLS가 없으니 REDIS_URL=redis://localhost:6379로 테스트한다.
const redis = new Redis(process.env.REDIS_URL);

function priceKey(auctionId) {
  return `auction:${auctionId}:price`;
}

// 경매 등록될 때(auctionRoutes.js POST /) 한 번 호출해서 시작가를 심어둔다.
// 이미 키가 있으면 덮어쓰지 않는다(NX) — 재시작/중복 호출로 가격이 리셋되는 걸 막는다.
export async function initAuctionPrice(auctionId, startPrice) {
  await redis.set(priceKey(auctionId), startPrice, 'NX');
}

// 입찰 시도. 성공/실패와 상관없이 "지금 기준 최고가"를 항상 같이 돌려준다.
export async function attemptBid(auctionId, price) {
  const [okFlag, currentPrice] = await redis.eval(
    BID_SCRIPT,
    1,
    priceKey(auctionId),
    price,
    MIN_INCREMENT,
  );

  return {
    accepted: Number(okFlag) === 1, // 가격 값이 아니라 스크립트가 준 성공 플래그로 판단
    currentPrice: Number(currentPrice),
  };
}

export default redis;
