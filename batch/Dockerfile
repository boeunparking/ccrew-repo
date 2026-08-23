# --- deps: 프로덕션 의존성만 설치 ---
FROM node:20-slim AS deps
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev --no-audit --no-fund && npm cache clean --force

# --- runtime ----
FROM node:20-slim
WORKDIR /app
ENV NODE_ENV=production

COPY --from=deps /app/node_modules ./node_modules
COPY package*.json ./
COPY worker.js ./
COPY src ./src

# root로 실행하지 않는다
USER node

# HTTP 포트를 열지 않는 상시 폴링 워커라 EXPOSE 없음, ALB에도 안 붙는다
CMD ["node", "worker.js"]
