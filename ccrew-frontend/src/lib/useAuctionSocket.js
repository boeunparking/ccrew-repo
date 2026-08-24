import { useEffect, useRef, useState } from 'react';

import { WS_BASE_URL } from './config.js';

/**
 * 경매 하나를 구독해서 다른 사람의 입찰을 실시간으로 받는다.
 * AuctionDetail.jsx에서 사용.
 *
 * 개발: ws://localhost:3000/ws
 * 배포: wss://api.cloudduck.cloud/ws → ALB → ECS
 *
 * 페이지 호스트가 아니라 API 호스트로 붙는다. 백엔드는 Origin을 검사하므로
 * 프론트 도메인이 백엔드 CORS_ORIGINS에 들어 있어야 연결된다.
 */
export function useAuctionSocket(auctionId, onBid) {
  const [connected, setConnected] = useState(false);
  const socketRef = useRef(null);
  const retryRef = useRef(0);
  const handlerRef = useRef(onBid);

  // 콜백이 바뀌어도 소켓을 다시 열지 않도록 ref에 담아둔다
  handlerRef.current = onBid;

  useEffect(() => {
    if (!auctionId) return;

    let closed = false;
    let timer;

    const connect = () => {
      const ws = new WebSocket(`${WS_BASE_URL}/ws?auctionId=${encodeURIComponent(auctionId)}`);
      socketRef.current = ws;

      ws.onopen = () => {
        setConnected(true);
        retryRef.current = 0;
      };

      ws.onmessage = (e) => {
        try {
          const msg = JSON.parse(e.data);
          if (msg.type === 'BID_PLACED') handlerRef.current?.(msg);
        } catch {
          /* 파싱 실패는 무시 */
        }
      };

      ws.onclose = () => {
        setConnected(false);
        if (closed) return;
        // 지수 백오프로 재연결 (최대 10초)
        const delay = Math.min(1000 * 2 ** retryRef.current++, 10000);
        timer = setTimeout(connect, delay);
      };

      ws.onerror = () => ws.close();
    };

    connect();

    return () => {
      closed = true;
      clearTimeout(timer);
      socketRef.current?.close();
    };
  }, [auctionId]);

  return { connected };
}
