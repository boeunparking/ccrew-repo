// 빌드 결과물에 그대로 복사되는 런타임 설정 파일.
// index.html이 번들보다 먼저 이 파일을 읽는다.
//
// 여기 값을 바꾸면 프론트를 다시 빌드하지 않고도 API 주소와 Cognito 설정을 바꿀 수 있다.
//   - ECS/컨테이너 배포: docker-entrypoint.sh가 API_BASE_URL 환경변수로 이 파일을 덮어쓴다
//   - S3 정적 배포:      이 파일 하나만 다시 올리고 CloudFront 무효화하면 끝
//
// ⚠ 운영 배포에서는 이 파일이 그대로 올라가지 않는다.
//   .github/workflows/deploy.yml 의 frontend 잡이 빌드 후 SSM에서 실제 값을 읽어
//   dist/config.js 를 통째로 다시 쓴다. 여기 값은 로컬 개발과 "값이 없을 때"의 기본값이다.
//
// cognito 값을 비워두면 로그인/회원가입 화면이 설정 오류를 표시한다 — 조용히 깨지는 것보다
// 낫다. 로컬에서 채울 값은 `terraform output cognito_frontend_contract` 로 확인한다.
window.__CCREW_CONFIG__ = {
  apiBaseUrl: '',

  cognito: {
    // 예: 'ap-northeast-2_AbCdEfGhI' (리전은 이 값 앞부분에서 자동으로 읽힌다)
    userPoolId: '',
    // 예: '1h57kf5cpq17m0eo2ehjas9pqu'
    clientId: '',
    // 예: 'https://cloud-duck-033177021117.auth.ap-northeast-2.amazoncognito.com'
    domain: '',
  },
};
