-- cloud-duck 경매 서비스 DB 스키마 초안
-- web/src/store.js, batch/src/routes/*.js 에서 실제 쓰이는 필드 기준으로 작성

-- ========================================
-- users: 회원가입/로그인 (authRoutes.js 기준)
-- ========================================
CREATE TABLE users (
  id            CHAR(36)     PRIMARY KEY,        -- crypto.randomUUID()
  email         VARCHAR(255) NOT NULL UNIQUE,     -- 로그인 아이디로도 씀
  password_hash VARCHAR(255) NOT NULL,            -- bcrypt.hash 결과
  nickname      VARCHAR(50)  NOT NULL,
  role          VARCHAR(20)  NOT NULL DEFAULT 'user',  -- 'user' | 'admin'
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ========================================
-- auctions: 경매 상품 (auctionRoutes.js 기준)
-- ========================================
CREATE TABLE auctions (
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

  FOREIGN KEY (seller_id) REFERENCES users(id)
);

-- 상품 이미지 (auctions.images 배열 → 별도 테이블로 분리)
CREATE TABLE auction_images (
  id          CHAR(36)  PRIMARY KEY,
  auction_id  CHAR(36)  NOT NULL,
  image_key   VARCHAR(500) NOT NULL,   -- S3 key
  sort_order  INT       NOT NULL DEFAULT 0,

  FOREIGN KEY (auction_id) REFERENCES auctions(id)
);

-- ========================================
-- bids: 입찰 내역 (bidRoutes.js 기준)
-- ========================================
CREATE TABLE bids (
  id          CHAR(36) PRIMARY KEY,
  auction_id  CHAR(36) NOT NULL,
  user_id     CHAR(36) NOT NULL,
  price       INT      NOT NULL,
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

  FOREIGN KEY (auction_id) REFERENCES auctions(id),
  FOREIGN KEY (user_id)    REFERENCES users(id)
);

-- 자주 조회하는 패턴에 맞춘 인덱스
CREATE INDEX idx_bids_auction_id ON bids(auction_id);
CREATE INDEX idx_bids_user_id ON bids(user_id);
CREATE INDEX idx_auctions_seller_id ON auctions(seller_id);
