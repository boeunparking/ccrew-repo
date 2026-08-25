import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import Nav from '../components/Nav.jsx'
import { api } from '../lib/api.js'
import { refreshUnreadNotifications } from '../lib/useUnreadNotifications.js'

const tabs = ['판매', '구매', '알림']

export default function MyPage() {
  const [active, setActive] = useState('판매')
  const [sellItems, setSellItems] = useState([])
  const [buyItems, setBuyItems] = useState([])
  const [notifications, setNotifications] = useState([])
  const [error, setError] = useState('')

  useEffect(() => {
    setError('')
    const load =
      active === '판매' ? api.mySales() :
      active === '구매' ? api.myPurchases() :
      api.myNotifications()

    load
      .then((d) => {
        if (active === '판매') setSellItems(d.items)
        else if (active === '구매') setBuyItems(d.items)
        else {
          setNotifications(d.items)
          // 탭을 연 시점에 읽음 처리한다. 목록은 읽음 처리 "전"의 상태를 들고 있으므로
          // 이번에 새로 확인한 알림이 화면에서는 계속 강조된 채로 남는다.
          if (d.unread > 0) {
            api.readNotifications()
              .then(refreshUnreadNotifications)
              // 읽음 처리 실패는 다음에 탭을 열면 다시 시도된다. 화면을 막을 이유가 없다.
              .catch(() => {})
          }
        }
      })
      .catch((e) => setError(e.message))
  }, [active])

  const statusColor = (status) => {
    if (status === '진행중' || status === '최고가') return '#141414'
    if (status === '낙찰완료' || status === '낙찰') return '#8C8C8C'
    return '#C4C4C4'
  }

  return (
    <div className="page-wrap">
      <Nav showCategories={false} />
      <div className="tabs">
        {tabs.map((t) => (
          <button key={t} className={`tab ${active === t ? 'active' : ''}`} onClick={() => setActive(t)}>
            {t}
          </button>
        ))}
      </div>

      {error && <p style={{ padding: 24, color: '#c0392b' }}>{error}</p>}

      {!error && active === '판매' && (
        <>
          <Link to="/auctions/new" className="fab">+ 새 경매 등록</Link>
          <div style={{ padding: '0 24px 24px' }}>
            {sellItems.map((item) => (
              <div className="listrow" key={item.id}>
                <span>{item.name}</span>
                <span>{item.info}</span>
                <span style={{ color: statusColor(item.status), fontWeight: 700 }}>{item.status}</span>
              </div>
            ))}
            {sellItems.length === 0 && <p style={{ color: '#8C8C8C' }}>등록한 상품이 없습니다.</p>}
          </div>
        </>
      )}

      {!error && active === '구매' && (
        <div style={{ padding: '24px' }}>
          {buyItems.map((item) => (
            <div className="listrow" key={item.id}>
              <span>{item.name}</span>
              <span>{item.info}</span>
              <span style={{ color: statusColor(item.status), fontWeight: 700 }}>{item.status}</span>
            </div>
          ))}
          {buyItems.length === 0 && <p style={{ color: '#8C8C8C' }}>입찰한 상품이 없습니다.</p>}
          <Link to="/bids" style={{ fontSize: 11, color: '#8C8C8C', textDecoration: 'underline' }}>
            전체 입찰 내역 보기 →
          </Link>
        </div>
      )}

      {!error && active === '알림' && (
        <div style={{ padding: '24px' }}>
          {notifications.map((n) => (
            <div
              className="listrow"
              key={n.id}
              // 방금 읽음 처리했더라도, 이번에 새로 확인한 알림은 이 화면에 머무는 동안
              // 계속 구분돼 보여야 어떤 게 새 소식이었는지 알 수 있다.
              style={n.read ? undefined : { background: '#FFFBEA' }}
            >
              <span style={{ fontWeight: n.read ? 400 : 700 }}>
                {n.type === 'WON' && '🎉 '}
                {n.message}
              </span>
              <span style={{ color: '#B5B5B5' }}>{new Date(n.createdAt).toLocaleString('ko-KR')}</span>
            </div>
          ))}
          {notifications.length === 0 && <p style={{ color: '#8C8C8C' }}>새 알림이 없습니다.</p>}
        </div>
      )}
    </div>
  )
}
