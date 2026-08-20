import { createClient } from 'redis';

let clientPromise = null;

/**
 * web과 동일한 Valkey에 붙는다. REDIS_URL이 없으면 null을 던져서
 * 호출부가 "이번 틱은 건너뛴다"로 처리하게 한다 (로컬 개발 편의).
 */
export function getRedisClient() {
  if (!process.env.REDIS_URL) return null;
  if (!clientPromise) {
    const client = createClient({ url: process.env.REDIS_URL });
    client.on('error', (e) => console.error('[redis] client error', e.message));
    clientPromise = client.connect().then(() => client);
  }
  return clientPromise;
}
