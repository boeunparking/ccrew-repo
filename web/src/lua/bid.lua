-- 동시 입찰 원자적 처리 스크립트
--
-- KEYS[1] = auction:{경매id}:price   (Valkey에 저장된 "현재 최고가")
-- ARGV[1] = 새로 들어온 입찰가
-- ARGV[2] = 최소 입찰 증가액 (예: 1000)
-- ARGV[3] = RDS 기준 현재가. 키가 없을 때 이 값으로 심고 진행한다 (없으면 빈 문자열)
--
-- Redis/Valkey는 Lua 스크립트 하나를 "한 번에 통째로" 실행한다.
-- 즉 이 스크립트가 도는 동안에는 다른 입찰 요청이 절대 끼어들 수 없다.
-- 그래서 "현재가 확인 → 비교 → 갱신"을 GET/SET 두 번으로 나누지 않고
-- 이 안에서 한 번에 처리하면 두 사람이 동시에 입찰해도 한 명만 이긴다.

local current = tonumber(redis.call('GET', KEYS[1]))
local newPrice = tonumber(ARGV[1])
local minIncrement = tonumber(ARGV[2])
local fallback = tonumber(ARGV[3])

-- 키가 없는 경우: Valkey는 캐시라 언제든 사라질 수 있다(장애 복구, flush, 노드 교체,
-- 경매 생성 시 initAuctionPrice가 실패한 경우). 예전엔 여기서 AUCTION_NOT_FOUND를
-- 던져 500이 났는데, RDS에 진짜 현재가가 있으므로 그 값으로 스스로 복구한다.
-- 심는 것까지 이 스크립트 안에서 해야 두 요청이 동시에 와도 하나만 심는다.
if current == nil then
  if fallback == nil then
    return redis.error_reply('AUCTION_NOT_FOUND')
  end
  current = fallback
  redis.call('SET', KEYS[1], current)
end

if newPrice < current + minIncrement then
  -- 실패: 늦게 도착했거나 너무 낮은 입찰가.
  -- 현재가를 그대로 돌려줘서 "얼마 이상 불러야 하는지" 호출한 쪽이 알 수 있게 한다.
  -- 성공/실패를 가격 값만으로 구분하면, 여러 명이 같은 가격을 부른 경우
  -- 실패자도 (마침 자기 입찰가와 같은) 현재가를 돌려받아 성공으로 오인될 수 있다.
  -- 그래서 성공 플래그를 값과 분리해 [0/1, price, previous] 형태로 돌려준다.
  return {0, current, current}
end

redis.call('SET', KEYS[1], newPrice)

-- 세 번째 값(직전 가격)은 되돌리기용이다. 이 입찰을 RDS에 기록하는 데 실패하면
-- 호출한 쪽이 이 값으로 Valkey를 원복해야 두 저장소가 어긋난 채 굳지 않는다.
return {1, newPrice, current}
