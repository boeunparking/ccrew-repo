# db

## 스키마 원본은 여기 없다

`db/schema.sql` 은 **`web/src/schema.sql` 로 옮겼다.**

문서가 아니라 실제로 실행되는 파일이 됐기 때문이다 — `web/server.js` 의 warmup이
부팅할 때마다 `web/src/schema.js` 를 통해 그대로 돌린다. 웹 이미지의 Docker 빌드
컨텍스트가 `web/` 라서, 그 바깥에 있으면 이미지에 들어가지 않는다.

사본을 두 벌 두면 반드시 어긋나므로 원본 한 벌만 남겼다.

## 그래서 DB는 누가 만드나

앱이 만든다. 부팅할 때 `CREATE DATABASE IF NOT EXISTS cloud_duck` 과
테이블 생성까지 스스로 한다. VPN으로 들어가서 mysql 클라이언트로 스키마를
밀어넣는 절차가 필요 없다.

RDS 모듈이 `db_name` 을 설정하지 않아서 apply만으로는 데이터베이스가 안 생기는데,
그 빈자리를 앱이 메우는 구조다.

## migrations/

`CREATE TABLE IF NOT EXISTS` 는 **이미 있는 테이블을 건드리지 않는다.**
그래서 운영 중인 DB의 컬럼을 바꾸거나 추가하는 건 `web/src/schema.sql` 을 고쳐도
반영되지 않는다. 그럴 때만 여기에 `ALTER` 문을 쓰고 한 번 직접 실행한다.

**DB를 새로 만드는 경우엔 아래 어느 것도 필요 없다** — `web/src/schema.sql` 이 이미
최종 모습이다. 아래는 전부 "이미 데이터가 들어있는 운영 DB"를 따라오게 만드는 용도다.
번호 순서대로 실행한다.

| 파일 | 언제 쓰나 |
|---|---|
| `001_oauth_identities.sql` | ~~소셜 로그인 도입~~ **더 이상 실행하지 말 것.** 003이 되돌리는 대상이라 지금 실행하면 만들자마자 지우는 꼴이 된다. 이력으로만 남겨둔다 |
| `002_image_moderation.sql` | 이미지 자동 검수(Rekognition) 결과를 반영할 컬럼을 붙일 때. `auctions.hidden_at`, `auction_images.moderation_status`, `image_moderation_rejections` 테이블 |
| `003_cognito_auth.sql` | 인증을 Cognito로 넘길 때. `users.password_hash`/`role` 을 지우고 `user_identities` 를 드롭한다 |

```bash
mysql -h <rds-endpoint> -u <user> -p cloud_duck < db/migrations/002_image_moderation.sql
mysql -h <rds-endpoint> -u <user> -p cloud_duck < db/migrations/003_cognito_auth.sql
```

> ⚠ `003` 은 비밀번호와 권한 정보를 **지운다**. 이 프로젝트는 기존 회원 데이터를
> 보존할 필요가 없다는 전제로 쓰였다. 관리자는 이후 Cognito의 `admin` 그룹
> 멤버십으로 판단하며, 최초 admin 계정은 terraform이 apply 시점에 만든다
> (`terraform/admin-credentials.tf`).
