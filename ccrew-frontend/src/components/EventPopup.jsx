import { useState } from 'react'
import { Link } from 'react-router-dom'

const HIDE_KEY = 'cd_popup_hide_until'

function todayStr() {
  return new Date().toISOString().slice(0, 10)
}

function shouldShow() {
  const hideUntil = localStorage.getItem(HIDE_KEY)
  return hideUntil !== todayStr()
}

export default function EventPopup() {
  const [visible, setVisible] = useState(shouldShow)

  if (!visible) return null

  const close = () => setVisible(false)
  const hideForToday = () => {
    localStorage.setItem(HIDE_KEY, todayStr())
    setVisible(false)
  }

  return (
    <div className="popup-overlay" onClick={close}>
      <div className="popup-window" onClick={(e) => e.stopPropagation()}>
        <div className="popup-banner">
          <div className="popup-eyebrow">Weekly Drop</div>
          <div className="popup-title">이번 주 신작 피규어<br />경매가 열렸습니다</div>
        </div>
        <div className="popup-body">
          <p>
            넨도로이드부터 스케일 피규어, 건프라까지 —<br />
            덕후들이 직접 올린 한정 수량 매물을 지금 만나보세요.
          </p>
          <Link to="/auctions" className="popup-cta" onClick={close}>
            경매 둘러보기
          </Link>
        </div>
        <div className="popup-footer">
          <button className="popup-hide-today" onClick={hideForToday}>
            오늘 하루 보지 않기
          </button>
          <button className="popup-close" onClick={close} aria-label="닫기">
            ✕
          </button>
        </div>
      </div>
    </div>
  )
}
