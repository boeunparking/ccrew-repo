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

// 진단/복구용. Valkey가 들고 있는 현재가를 그대로 읽는다 (키가 없으면 null).
export async function getBidPrice(auctionId) {
  const raw = await redis.get(priceKey(auctionId));
  return raw === null ? null : Number(raw);
}

/**
 * 입찰 시도. 성공/실패와 상관없이 "지금 기준 최고가"를 항상 같이 돌려준다.
 *
 * fallbackPrice(RDS의 current_price)는 Valkey에 키가 없을 때 심을 값이다.
 * Valkey는 영속 저장소가 아니라 언제든 키가 사라질 수 있는데, 예전에는 그때
 * AUCTION_NOT_FOUND로 500이 나면서 그 경매가 통째로 입찰 불가가 됐다.
 */
export async function attemptBid(auctionId, price, fallbackPrice) {
  const [okFlag, currentPrice, previousPrice] = await redis.eval(
    BID_SCRIPT,
    1,
    priceKey(auctionId),
    price,
    MIN_INCREMENT,
    // Lua쪽 tonumber('')가 nil이 되도록, 값이 없으면 빈 문자열을 넘긴다
    Number.isFinite(fallbackPrice) ? fallbackPrice : '',
  );

  return {
    accepted: Number(okFlag) === 1, // 가격 값이 아니라 스크립트가 준 성공 플래그로 판단
    currentPrice: Number(currentPrice),
    previousPrice: Number(previousPrice),
  };
}

// 방금 올린 가격이 아직 그대로일 때만 되돌린다.
// 그 사이 다른 사람이 더 높게 입찰했다면(값이 바뀌었다면) 건드리면 안 된다 —
// 그건 정상적으로 성립한 입찰이라 되돌리면 그쪽 기록과 어긋난다.
const ROLLBACK_SCRIPT = `
local current = tonumber(redis.call('GET', KEYS[1]))
if current ~= nil and current == tonumber(ARGV[1]) then
  redis.call('SET', KEYS[1], ARGV[2])
  return 1
end
return 0
`;

/**
 * Valkey에서는 통과했지만 RDS 기록에 실패한 입찰을 원복한다.
 *
 * 이걸 안 하면 Valkey 현재가만 앞서간 채로 굳는다 — 화면(RDS)은 151,000원인데
 * 판정(Valkey)은 그보다 높은 값을 기준으로 하니, 그 경매는 누가 무슨 값을 넣어도
 * "1,000원 이상 높게 입찰해 주세요"만 나오는 상태가 된다.
 */
export async function rollbackBid(auctionId, acceptedPrice, previousPrice) {
  const restored = await redis.eval(
    ROLLBACK_SCRIPT,
    1,
    priceKey(auctionId),
    acceptedPrice,
    previousPrice,
  );
  return Number(restored) === 1;
}

/**
 * Valkey 현재가를 RDS 값으로 강제로 맞춘다 (관리자 복구용).
 *
 * 이미 어긋난 채 굳어버린 경매를 되살리는 수단이다. 낮추는 방향이라 진행 중인
 * 입찰을 덮어쓸 수 있으므로 자동으로 호출하지 않는다 — adminRoutes에서만 쓴다.
 */
export async function resyncAuctionPrice(auctionId, price) {
  await redis.set(priceKey(auctionId), price);
}

export default redis;
