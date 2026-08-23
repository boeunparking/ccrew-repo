import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// API가 api.cloudduck.cloud 서브도메인으로 분리되면서 프록시가 필요 없어졌다.
// 개발에서도 배포와 똑같이 절대 URL(http://localhost:3000)로 직접 호출하고,
// 백엔드 CORS_ORIGINS에 http://localhost:5173 이 들어 있어서 통과한다.
// 프록시로 같은 출처인 척하면 개발에서만 CORS 문제가 안 보이는 함정이 생긴다.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
  },
});
