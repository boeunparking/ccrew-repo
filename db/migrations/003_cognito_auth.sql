-- 인증을 AWS Cognito User Pool로 이전하는 마이그레이션
--
-- schema.sql은 "지금의 전체 모습"이라 이미 떠 있는 RDS에는 적용할 수 없다.
-- 운영 DB에는 이 파일을 한 번 실행한다.
--
--   mysql -h <rds-endpoint> -u <user> -p cloud_duck < db/migrations/003_cognito_auth.sql
--
-- 회원가입/로그인/소셜 연동을 Cognito가 전담하게 되면서, 비밀번호와 role은
-- 더 이상 이 DB가 들고 있지 않는다(role은 Cognito의 admin 그룹 멤버십으로 대체).
-- 이 프로젝트는 포트폴리오/테스트 용도라 기존 회원 데이터를 보존할 필요가 없으므로,
-- 값을 옮기는 대신 그냥 걷어낸다.

ALTER TABLE users
  DROP COLUMN password_hash,
  DROP COLUMN role;

DROP TABLE IF EXISTS user_identities;
