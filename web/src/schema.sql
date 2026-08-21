-- cloud-duck 경매 서비스 DB 스키마
--
-- 이 파일은 문서가 아니라 실행된다 — server.js 의 warmup이 부팅할 때마다
-- src/schema.js 를 통해 그대로 돌린다. 그래서 두 가지 규칙이 있다:
--   1. 몇 번을 다시 돌려도 안전해야 한다 (전부 IF NOT EXISTS)
--   2. CREATE INDEX 는 MySQL에 IF NOT EXISTS가 없으므로 테이블 정의 안에 KEY로 넣는다
--
-- 이미 데이터가 든 DB의 스키마를 "바꾸는" 건 이 파일로 안 된다.
-- CREATE TABLE IF NOT EXISTS 는 기존 테이블을 건드리지 않기 때문이다.
-- 그때는 db/migrations/ 에 ALTER 문을 따로 쓴다.

-- ========================================
-- users: 회원가입/로그인 + 소셜 로그인 (routes/authRoutes.js, routes/oauthRoutes.js)
-- ========================================
CREATE TABLE IF NOT EXISTS users (
  id            CHAR(36)     PRIMARY KEY,        -- crypto.randomUUID()
  email         VARCHAR(255) NOT NULL UNIQUE,     -- 로그인 아이디로도 씀
  password_hash VARCHAR(255) NULL,                -- bcrypt.hash 결과. 소셜 전용 계정은 NULL
  nickname      VARCHAR(50)  NOT NULL,
  role          VARCHAR(20)  NOT NULL DEFAULT 'user',  -- 'user' | 'admin'
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ========================================
-- user_identities: 소셜 계정 연결 (routes/oauthRoutes.js)
-- ========================================
-- 한 계정에 구글·카카오를 둘 다 붙일 수 있어서 users와 1:N으로 뺐다.
-- 공급자가 주는 provider_user_id는 이메일과 달리 바뀌지 않으므로
-- "누구인가"는 항상 이 값으로 판단한다.
CREATE TABLE IF NOT EXISTS user_identities (
  id               CHAR(36)     PRIMARY KEY,
  user_id          CHAR(36)     NOT NULL,
  provider         VARCHAR(20)  NOT NULL,        -- 'google' | 'kakao'
  provider_user_id VARCHAR(255) NOT NULL,        -- google: sub, kakao: id
  email            VARCHAR(255),                 -- 연결 당시 공급자가 알려준 값(참고용)
  created_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  -- 같은 소셜 계정이 서로 다른 우리 계정 두 개에 붙는 걸 막는다
  UNIQUE KEY uq_identity (provider, provider_user_id),
  -- 한 사용자가 같은 공급자를 중복 연결하는 것도 막는다
  UNIQUE KEY uq_user_provider (user_id, provider),

  FOREIGN KEY (user_id) REFERENCES users(id)
);

-- ========================================
-- auctions: 경매 상품 (auctionRoutes.js 기준)
-- ========================================
CREATE TABLE IF NOT EXISTS auctions (
  id            CHAR(36)     PRIMARY KEY,
  name          VARCHAR(255) NOT NULL,
  brand         VARCHAR(100) NOT NULL DEFAULT '기타',
  category      VARCHAR(50)  NOT NULL DEFAULT 'etc',
  description   TEXT,
  start_price   INT          NOT NULL,
  current_price INT          NOT NULL,            -- ⚠ 동시 입찰 시 race condition 나는 그 컬럼
  ends_at       DATETIME     NOT NULL,
  seller_id     CHAR(36)     NOT NULL,
  tag           VARCHAR(20),                      -- 'NEW', '마감임박' 등
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  KEY idx_auctions_seller_id (seller_id),
  FOREIGN KEY (seller_id) REFERENCES users(id)
);

-- 상품 이미지 (auctions.images 배열 → 별도 테이블로 분리)
CREATE TABLE IF NOT EXISTS auction_images (
  id          CHAR(36)  PRIMARY KEY,
  auction_id  CHAR(36)  NOT NULL,
  image_key   VARCHAR(500) NOT NULL,   -- S3 key
  sort_order  INT       NOT NULL DEFAULT 0,

  FOREIGN KEY (auction_id) REFERENCES auctions(id)
);

-- ========================================
-- bids: 입찰 내역 (bidRoutes.js 기준)
-- ========================================
CREATE TABLE IF NOT EXISTS bids (
  id          CHAR(36) PRIMARY KEY,
  auction_id  CHAR(36) NOT NULL,
  user_id     CHAR(36) NOT NULL,
  price       INT      NOT NULL,
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

  -- 자주 조회하는 패턴에 맞춘 인덱스
  KEY idx_bids_auction_id (auction_id),
  KEY idx_bids_user_id (user_id),

  FOREIGN KEY (auction_id) REFERENCES auctions(id),
  FOREIGN KEY (user_id)    REFERENCES users(id)
);
