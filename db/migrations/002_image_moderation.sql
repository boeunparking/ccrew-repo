-- Rekognition 이미지 모더레이션 후속 처리 마이그레이션
--
-- schema.sql은 "지금의 전체 모습"이라 이미 떠 있는 RDS에는 적용할 수 없다.
-- 운영 DB에는 이 파일을 한 번 실행한다.
--
--   mysql -h <rds-endpoint> -u <user> -p cloud_duck < db/migrations/002_image_moderation.sql

ALTER TABLE auctions
  ADD COLUMN hidden_at     DATETIME     NULL,
  ADD COLUMN hidden_reason VARCHAR(255) NULL;

ALTER TABLE auction_images
  ADD COLUMN moderation_status VARCHAR(20)  NOT NULL DEFAULT 'PENDING',
  ADD COLUMN moderation_labels VARCHAR(255) NULL,
  ADD COLUMN moderated_at      DATETIME     NULL;

CREATE TABLE IF NOT EXISTS image_moderation_rejections (
  image_key   VARCHAR(500) PRIMARY KEY,
  labels      VARCHAR(255),
  rejected_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
