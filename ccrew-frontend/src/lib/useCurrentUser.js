import { useEffect, useState } from 'react';
import { api, auth } from './api.js';

/**
 * 현재 로그인한 사용자를 돌려준다. 로그인 안 했으면 null.
 *
 * Nav가 모든 페이지에 렌더되기 때문에, 훅이 마운트마다 /auth/me를 부르면
 * 페이지를 옮길 때마다 같은 요청이 나간다. 그래서 결과를 모듈 수준에 한 번만
 * 캐시하고, 이후 마운트는 캐시를 그대로 쓴다.
 *
 * localStorage의 토큰만 보고 이름을 띄울 수는 없다 — 토큰에 닉네임이 들어있지
 * 않고, 만료된 토큰이 남아있을 수도 있다. 서버에 한 번 물어보는 게 맞다.
 */

let cache = null; // 마지막으로 확인된 사용자 (null = 미확인 또는 비로그인)
let pending = null; // 진행 중인 요청. 동시에 여러 Nav가 떠도 요청은 하나만 나가게 한다.
const subscribers = new Set();

function publish(user) {
  cache = user;
  subscribers.forEach((notify) => notify(user));
}

function load() {
  if (pending) return pending;

  pending = api
    .me()
    .then((user) => {
      publish(user);
      return user;
    })
    .catch(() => {
      // 토큰이 만료됐거나 서버가 거절한 경우. api.request가 401이면 토큰을 이미
      // 지우므로, 여기서는 비로그인 상태로 떨어뜨리기만 하면 된다.
      publish(null);
      return null;
    })
    .finally(() => {
      pending = null;
    });

  return pending;
}

/**
 * 로그인/로그아웃 직후에 호출한다.
 * 캐시를 버리고 다시 확인해서, 구독 중인 Nav가 즉시 갱신되게 한다.
 */
export function refreshCurrentUser() {
  pending = null;

  if (!auth.isLoggedIn()) {
    publish(null);
    return;
  }

  load();
}

export function useCurrentUser() {
  const [user, setUser] = useState(cache);

  useEffect(() => {
    subscribers.add(setUser);

    if (!auth.isLoggedIn()) {
      // 다른 탭에서 로그아웃했거나 토큰이 지워진 경우 캐시가 남아있을 수 있다.
      if (cache) publish(null);
    } else if (cache === null) {
      load();
    }

    return () => {
      subscribers.delete(setUser);
    };
  }, []);

  return user;
}
