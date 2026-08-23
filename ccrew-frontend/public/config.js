// 빌드 결과물에 그대로 복사되는 런타임 설정 파일.
// index.html이 번들보다 먼저 이 파일을 읽는다.
//
// 여기 값을 바꾸면 프론트를 다시 빌드하지 않고도 API 주소를 바꿀 수 있다.
//   - ECS/컨테이너 배포: docker-entrypoint.sh가 API_BASE_URL 환경변수로 이 파일을 덮어쓴다
//   - S3 정적 배포:      이 파일 하나만 다시 올리고 CloudFront 무효화하면 끝
//
// 비워두면 src/lib/config.js의 기본값(https://api.cloudduck.cloud)을 쓴다.
window.__CCREW_CONFIG__ = {
  apiBaseUrl: '',
};
