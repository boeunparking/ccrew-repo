import { createClient } from 'redis';

let clientPromise = null;

/**
 * REDIS_URL이 없으면 null (로컬 개발 등에서 폴백 경로를 타게 함).
 * 있으면 프로세스당 커넥션 하나만 만들어 재사용한다.
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
