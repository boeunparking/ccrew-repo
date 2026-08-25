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

-- ========================================
-- notifications: 사용자별 알림 (routes/meRoutes.js 알림 탭)
-- ========================================
-- 경매가 마감되면 batch 워커가 낙찰자에게 WON, 나머지 입찰자에게 LOST 를 한 건씩 넣는다.
-- (batch/src/jobs.js — 이메일 발송과 같은 자리에서 만든다)
--
-- auction_id 에 FK 를 걸지 않는 이유: 관리자가 경매를 삭제할 때(store.js deleteAuction)
-- FK 가 있으면 삭제가 거부된다. 알림은 "그때 이런 일이 있었다"는 기록이라 원본 경매가
-- 사라져도 남아 있는 편이 맞다. 대신 deleteAuction 이 같이 정리한다.
CREATE TABLE IF NOT EXISTS notifications (
  id          CHAR(36)     PRIMARY KEY,
  user_id     CHAR(36)     NOT NULL,
  auction_id  CHAR(36)     NULL,
  type        VARCHAR(20)  NOT NULL,      -- 'WON' | 'LOST'
  message     VARCHAR(255) NOT NULL,
  read_at     DATETIME     NULL,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  -- 알림 탭은 "내 알림을 최신순으로"만 조회한다
  KEY idx_notifications_user (user_id, created_at),

  -- 워커는 30초마다 돌고 재시도도 한다. 같은 경매·같은 종류의 알림이 그때마다
  -- 쌓이지 않도록 DB 레벨에서 막는다 (INSERT IGNORE 와 짝).
  UNIQUE KEY uk_notifications_dedupe (user_id, auction_id, type),

  FOREIGN KEY (user_id) REFERENCES users(id)
);
