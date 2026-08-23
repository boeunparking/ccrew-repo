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
-- users: Cognito가 인증한 사용자의 프로필 사본 (routes/authRoutes.js)
-- ========================================
-- 회원가입/로그인/소셜 연동은 전부 Cognito User Pool이 처리한다. 여기 있는 id는
-- Cognito의 sub(UUID)을 그대로 쓰고, auctions.seller_id/bids.user_id가 이 테이블을
-- FK로 참조하기 때문에만 존재한다 — authMiddleware.js가 인증된 요청마다 upsert한다.
CREATE TABLE IF NOT EXISTS users (
  id            CHAR(36)     PRIMARY KEY,        -- Cognito sub
  email         VARCHAR(255) NOT NULL UNIQUE,
  nickname      VARCHAR(50)  NOT NULL,
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
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
  -- Rekognition이 이미지를 REJECTED로 판정하면 채워진다 (terraform/modules/lambda/image_moderation).
  -- NULL이 아니면 공개 목록/상세에서 제외된다 (store.js listAuctions/getAuctionById).
  hidden_at     DATETIME     NULL,
  hidden_reason VARCHAR(255) NULL,

  KEY idx_auctions_seller_id (seller_id),
  FOREIGN KEY (seller_id) REFERENCES users(id)
);

-- 상품 이미지 (auctions.images 배열 → 별도 테이블로 분리)
CREATE TABLE IF NOT EXISTS auction_images (
  id                 CHAR(36)  PRIMARY KEY,
  auction_id         CHAR(36)  NOT NULL,
  image_key          VARCHAR(500) NOT NULL,   -- S3 key
  sort_order         INT       NOT NULL DEFAULT 0,
  -- 'PENDING' | 'APPROVED' | 'REJECTED' — image_moderation Lambda가 채운다.
  -- 업로드 직후 auctions API가 이미지를 먼저 걸고, Rekognition 판정은 비동기로
  -- 뒤늦게 오므로 기본값은 PENDING이다.
  moderation_status  VARCHAR(20)  NOT NULL DEFAULT 'PENDING',
  moderation_labels  VARCHAR(255) NULL,
  moderated_at       DATETIME     NULL,

  FOREIGN KEY (auction_id) REFERENCES auctions(id)
);

-- 이미지가 REJECTED로 판정될 때 아직 auction_images 행이 없을 수 있다 —
-- 업로드(S3 presign)는 경매 생성보다 먼저 일어나고, Rekognition은 보통 그 사이의
-- 짧은 창(사용자가 나머지 폼을 채우는 동안) 안에 끝나기 때문이다. 그래서 판정 결과를
-- image_key만으로 독립적으로 남겨두고, createAuction()이 경매를 만들 때 이 테이블을
-- 조회해서 즉시 반영한다 (web/src/store.js).
CREATE TABLE IF NOT EXISTS image_moderation_rejections (
  image_key   VARCHAR(500) PRIMARY KEY,
  labels      VARCHAR(255),
  rejected_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
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
