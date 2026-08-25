import { useEffect, useState } from 'react';
import { api, auth } from './api.js';

/**
 * 안 읽은 알림 개수. 비로그인이면 0.
 *
 * useCurrentUser.js와 같은 구조다 — Nav가 모든 페이지에 렌더되므로, 훅이 마운트마다
 * 요청하면 페이지를 옮길 때마다 같은 요청이 나간다. 모듈 수준에 한 번 캐시하고
 * 구독자에게 뿌린다.
 *
 * 알림은 워커가 30초 주기로 만들기 때문에, 화면을 켜둔 사이에 생긴 알림을 보려면
 * 주기적으로 다시 물어봐야 한다. WebSocket은 지금 경매별 채널만 있어서 사용자 단위
 * 푸시에 못 쓴다 — 그래서 가벼운 폴링을 쓴다. 요청은 개인 알림 최대 50건이라 싸다.
 */

const POLL_INTERVAL_MS = 60_000;

let cache = 0;
let pending = null;
let timer = null;
const subscribers = new Set();

function publish(count) {
  cache = count;
  subscribers.forEach((notify) => notify(count));
}

function load() {
  if (pending) return pending;

  pending = api
    .myNotifications()
    .then((d) => {
      publish(d.unread ?? 0);
      return d.unread ?? 0;
    })
    // 알림 뱃지는 부가 정보다. 실패하면 조용히 0으로 두고 화면을 막지 않는다.
    .catch(() => {
      publish(0);
      return 0;
    })
    .finally(() => {
      pending = null;
    });

  return pending;
}

/** 알림을 읽음 처리한 직후 등, 개수가 바뀐 걸 아는 쪽에서 호출한다. */
export function refreshUnreadNotifications() {
  pending = null;
  if (!auth.isLoggedIn()) {
    publish(0);
    return;
  }
  load();
}

export function useUnreadNotifications() {
  const [count, setCount] = useState(cache);

  useEffect(() => {
    subscribers.add(setCount);

    if (!auth.isLoggedIn()) {
      if (cache !== 0) publish(0);
    } else {
      load();
      // 구독자가 여러 개(Nav가 여러 번 마운트)여도 타이머는 하나만 돈다.
      if (!timer) {
        timer = setInterval(() => {
          if (auth.isLoggedIn()) load();
        }, POLL_INTERVAL_MS);
      }
    }

    return () => {
      subscribers.delete(setCount);
      if (subscribers.size === 0 && timer) {
        clearInterval(timer);
        timer = null;
      }
    };
  }, []);

  return count;
}
