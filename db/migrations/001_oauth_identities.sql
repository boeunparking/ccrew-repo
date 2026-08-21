-- 소셜 로그인(OAuth 2.0) 도입 마이그레이션
--
-- schema.sql은 "지금의 전체 모습"이라 이미 떠 있는 RDS에는 적용할 수 없다.
-- 운영 DB에는 이 파일을 한 번 실행한다.
--
--   mysql -h <rds-endpoint> -u <user> -p cloud_duck < db/migrations/001_oauth_identities.sql

-- 소셜로만 가입한 계정은 비밀번호가 없다.
ALTER TABLE users MODIFY password_hash VARCHAR(255) NULL;

CREATE TABLE IF NOT EXISTS user_identities (
  id               CHAR(36)     PRIMARY KEY,
  user_id          CHAR(36)     NOT NULL,
  provider         VARCHAR(20)  NOT NULL,
  provider_user_id VARCHAR(255) NOT NULL,
  email            VARCHAR(255),
  created_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  UNIQUE KEY uq_identity (provider, provider_user_id),
  UNIQUE KEY uq_user_provider (user_id, provider),

  FOREIGN KEY (user_id) REFERENCES users(id)
);
