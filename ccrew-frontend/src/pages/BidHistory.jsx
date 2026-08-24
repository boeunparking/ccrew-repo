import { useState, useEffect } from "react";
import Nav from "../components/Nav.jsx";
import { api } from "../lib/api.js";

function fmtTime(sec) {
  if (sec <= 0) return "종료";
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  if (h > 0)
    return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

function statusOf(item) {
  if (item.ended) return { label: "낙찰완료", cls: "done" };
  if (item.price <= item.myBid) return { label: "최고가", cls: "top" };
  return { label: "경쟁중", cls: "mid" };
}

export default function BidHistory() {
  const [items, setItems] = useState([]);
  const [summary, setSummary] = useState({ total: 0, leading: 0, competing: 0, closingSoon: 0 });
  const [error, setError] = useState("");

  const load = () => {
    api.myBids()
      .then((d) => {
        setItems(d.items);
        setSummary(d.summary);
        setError("");
      })
      .catch((e) => setError(e.message));
  };

  useEffect(() => {
    load();
    // 서버가 실제 데이터를 갖고 있으므로, 5초마다 다시 물어보는 것으로
    // 프론트 랜덤 시뮬레이션을 대체한다. 실제 실시간성은 AuctionDetail의
    // WebSocket 쪽에서 처리되고, 여기는 목록 화면이라 폴링으로 충분하다.
    const timer = setInterval(load, 5000);
    return () => clearInterval(timer);
  }, []);

  if (error) {
    return (
      <div className="page-wrap">
        <Nav showCategories={false} />
        <p style={{ padding: 24, color: "#c0392b" }}>{error}</p>
      </div>
    );
  }

  return (
    <div className="page-wrap">
      <Nav showCategories={false} />

      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          padding: "22px 24px 0",
        }}
      >
        <div
          style={{ fontFamily: "var(--serif)", fontSize: 22, fontWeight: 700 }}
        >
          입찰 내역
        </div>
        <div className="live-label">
          <span className="live-dot" />
          실시간 반영 중
        </div>
      </div>

      <div className="summary" style={{ margin: "20px 24px 0" }}>
        <div className="cell">
          <div className="label">참여 중</div>
          <div className="value">{summary.total}</div>
        </div>
        <div className="cell">
          <div className="label">최고가</div>
          <div className="value">{summary.leading}</div>
        </div>
        <div className="cell">
          <div className="label">경쟁중</div>
          <div className="value">{summary.competing}</div>
        </div>
        <div className="cell">
          <div className="label">마감임박</div>
          <div className="value">{summary.closingSoon}</div>
        </div>
      </div>

      <div className="tickerlist">
        {items.map((item) => {
          const diff = item.price - item.myBid;
          const st = statusOf(item);
          return (
            <div key={item.id} className="tl-row">
              <div className="tl-info">
                <div className="tl-name">{item.name}</div>
                <div className="tl-seller">{item.seller}</div>
              </div>
              <div className="tl-price">
                <div className="tl-current mono">
                  {item.price.toLocaleString()}원{" "}
                  {diff > 0 && <span className="arrow-up">▲</span>}
                </div>
                <div className="tl-sub">
                  {diff === 0
                    ? "최고가 유지 중"
                    : `내 입찰가보다 ${diff.toLocaleString()}원 높음`}
                </div>
              </div>
              <div className="tl-time mono">{fmtTime(item.secondsLeft)}</div>
              <span className={`badge3 ${st.cls}`}>{st.label}</span>
            </div>
          );
        })}
      </div>

      {items.length === 0 && (
        <p style={{ padding: "24px", color: "#8C8C8C" }}>참여 중인 입찰이 없습니다.</p>
      )}

      <p style={{ fontSize: 11, color: "#B5B5B5", margin: "16px 24px" }}>
        ▲ = 나보다 높은 입찰 발생 · 5초마다 갱신됩니다
      </p>
    </div>
  );
}
