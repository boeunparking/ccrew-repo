import { useState, useEffect, useRef } from "react";
import { useParams, Link } from "react-router-dom";
import Nav from "../components/Nav.jsx";
import { api, auth } from "../lib/api.js";
import { useAuctionSocket } from "../lib/useAuctionSocket.js";

function formatTime(sec) {
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

export default function AuctionDetail() {
  const { id } = useParams();

  const [auction, setAuction] = useState(null);
  const [related, setRelated] = useState([]);
  const [secondsLeft, setSecondsLeft] = useState(0);
  const [currentPrice, setCurrentPrice] = useState(0);
  const [bidderCount, setBidderCount] = useState(0);
  const [history, setHistory] = useState([]);
  const [bidInput, setBidInput] = useState("");
  const [wishlisted, setWishlisted] = useState(false);
  const [flash, setFlash] = useState(false);
  const [activeThumb, setActiveThumb] = useState(0);
  const [error, setError] = useState("");
  const flashTimeout = useRef(null);

  // 최초 로드
  useEffect(() => {
    api
      .getAuction(id)
      .then((a) => {
        setAuction(a);
        setCurrentPrice(a.currentPrice);
        setSecondsLeft(a.secondsLeft);
        setBidderCount(a.bidderCount);
        setHistory(a.history);
      })
      .catch((e) => setError(e.message));

    api
      .getRelated(id)
      .then((d) => setRelated(d.items))
      .catch(() => {});
  }, [id]);

  // 로컬 카운트다운 (화면용, 서버 값과 별개로 매초 감소)
  useEffect(() => {
    const timer = setInterval(() => {
      setSecondsLeft((s) => (s > 0 ? s - 1 : 0));
    }, 1000);
    return () => clearInterval(timer);
  }, []);

  const runFlash = () => {
    setFlash(true);
    clearTimeout(flashTimeout.current);
    flashTimeout.current = setTimeout(() => setFlash(false), 400);
  };

  // 다른 사람이 입찰하면 여기로 실시간으로 들어온다
  useAuctionSocket(id, (msg) => {
    setCurrentPrice(msg.currentPrice);
    setSecondsLeft(msg.secondsLeft);
    setHistory((prev) => [
      { user: msg.bidder, price: msg.currentPrice, at: msg.at },
      ...prev,
    ]);
    setBidderCount((c) => c + 1);
    runFlash();
  });

  const placeBid = async (amount) => {
    if (!amount) return;
    if (!auth.isLoggedIn()) {
      setError("로그인이 필요합니다 ");
      return;
    }
    setError("");
    try {
      // 성공하면 내 화면은 WebSocket 브로드캐스트로 되돌아와서 갱신된다.
      // 그래도 체감 지연 없이 바로 보이도록 낙관적으로 먼저 반영한다.
      await api.placeBid(id, amount);
      setCurrentPrice(amount);
      runFlash();
    } catch (e) {
      // 거절당했다면 서버가 실제 기준 현재가를 같이 보내준다. 그걸로 화면을 맞춰야
      // 다음 +1,000 버튼이 진짜 최소가를 계산한다 — 안 그러면 낡은 값으로 계속
      // 재시도하면서 같은 400만 반복하게 된다.
      if (Number.isFinite(e.data?.currentPrice)) {
        setCurrentPrice(e.data.currentPrice);
      }
      setError(
        Number.isFinite(e.data?.minimum)
          ? `${e.message} (최소 ${e.data.minimum.toLocaleString()}원)`
          : e.message,
      );
    }
  };

  const handleBidSubmit = (e) => {
    e.preventDefault();
    placeBid(Number(bidInput));
    setBidInput("");
  };

  const quickBid = (increment) => placeBid(currentPrice + increment);

  if (!auction) {
    return (
      <div className="page-wrap">
        <Nav showCategories={false} />
        <p style={{ padding: 24, color: error ? "#c0392b" : "#8C8C8C" }}>
          {error || "불러오는 중..."}
        </p>
      </div>
    );
  }

  return (
    <div className="page-wrap">
      <Nav showCategories={false} />

      <div className="detail-wrap">
        <div className="gallery">
          <div
            className="gallery-main"
            style={
              auction.images[activeThumb]
                ? {
                    backgroundImage: `url(${auction.images[activeThumb]})`,
                    backgroundSize: "cover",
                    backgroundPosition: "center",
                  }
                : undefined
            }
          />
          <div className="gallery-thumbs">
            {(auction.images.length > 0
              ? auction.images
              : [null, null, null, null]
            ).map((img, i) => (
              <div
                key={i}
                className={`thumb ${activeThumb === i ? "active" : ""}`}
                onClick={() => setActiveThumb(i)}
                style={
                  img
                    ? {
                        backgroundImage: `url(${img})`,
                        backgroundSize: "cover",
                        backgroundPosition: "center",
                      }
                    : undefined
                }
              />
            ))}
          </div>
        </div>

        <div className="detail-right">
          <div className="detail-brand">
            {auction.brand} · 경매 #{id}
          </div>
          <div className="detail-title">{auction.name}</div>

          <div className="social-proof">
            <b>{bidderCount}명</b>이 입찰에 참여하고 있어요
          </div>

          <div className="timer-box">
            <span className="dot" />
            마감까지 {formatTime(secondsLeft)}
          </div>

          {/* 등록할 때 정한 마감 시각. 카운트다운이 맞는지 눈으로 확인할 수 있어야 한다.
              서버는 UTC로 주고, 여기서 보는 사람의 시간대로 표시된다. */}
          {auction.endsAt && (
            <div style={{ fontSize: 12, color: "#8C8C8C", margin: "-8px 0 14px" }}>
              마감 {new Date(auction.endsAt).toLocaleString("ko-KR")}
            </div>
          )}

          <div className="price-box">
            <div className="label">현재 최고가</div>
            <div className={`big ${flash ? "flash" : ""}`}>
              {currentPrice.toLocaleString()}원
            </div>
          </div>

          {error && (
            <div
              style={{
                color: "#c0392b",
                fontSize: 13,
                marginBottom: 12,
                padding: "8px 12px",
                background: "#fdecea",
                borderRadius: 6,
              }}
            >
              {error}
            </div>
          )}

          <div className="quickbid-row">
            <button className="quickbid-btn" onClick={() => quickBid(1000)}>
              +1,000
            </button>
            <button className="quickbid-btn" onClick={() => quickBid(5000)}>
              +5,000
            </button>
            <button className="quickbid-btn" onClick={() => quickBid(10000)}>
              +10,000
            </button>
          </div>

          <form className="bidform" onSubmit={handleBidSubmit}>
            <input
              placeholder={`직접 입력 (최소 ${(currentPrice + 1000).toLocaleString()}원)`}
              value={bidInput}
              onChange={(e) => setBidInput(e.target.value)}
              type="number"
            />
            <button type="submit" className="btn btn-dark">
              입찰하기
            </button>
          </form>

          <div className="wishlist-row">
            <button
              className={`wishlist-btn ${wishlisted ? "active" : ""}`}
              onClick={() => setWishlisted(!wishlisted)}
              aria-label="관심 경매 등록"
            >
              {wishlisted ? "♥" : "♡"}
            </button>
            <span className="wishlist-note">
              관심 경매로 등록하면 마감 임박 시 알림을 받아요
            </span>
          </div>

          <div className="hist">
            <div className="hist-head">
              <span className="t">실시간 입찰 이력</span>
            </div>
            {history.map((h, i) => (
              <div className="row" key={i}>
                <span>{h.user}</span>
                <span>{h.price.toLocaleString()}원</span>
              </div>
            ))}
          </div>

          <div className="desc">
            <div
              style={{
                fontWeight: 700,
                marginBottom: 6,
                color: "var(--black)",
              }}
            >
              판매자: {auction.seller}
            </div>
            {auction.description}
          </div>
        </div>
      </div>

      {related.length > 0 && (
        <div className="related-strip">
          <div className="section-head" style={{ padding: "0 0 18px" }}>
            <div>
              <div className="section-eyebrow">You May Also Like</div>
              <div className="section-title">함께 보면 좋은 경매</div>
            </div>
          </div>
          <div className="grid3" style={{ padding: 0 }}>
            {related.map((item) => (
              <Link key={item.id} to={`/auctions/${item.id}`} className="card">
                <div
                  className="cardimg"
                  style={{
                    aspectRatio: "3 / 4",
                    height: "auto",
                    backgroundImage: item.thumbnail
                      ? `url(${item.thumbnail})`
                      : undefined,
                    backgroundSize: "cover",
                    backgroundPosition: "center",
                  }}
                />
                <div className="brand">{item.brand}</div>
                <div className="name">{item.name}</div>
                <div className="price">{item.price.toLocaleString()}원</div>
              </Link>
            ))}
          </div>
        </div>
      )}

      <div className="sticky-bid-bar">
        <div className="cur">
          현재가<b>{currentPrice.toLocaleString()}원</b>
        </div>
        <button className="btn btn-dark" onClick={() => quickBid(1000)}>
          바로 입찰하기
        </button>
      </div>
    </div>
  );
}
