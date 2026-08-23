import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import { api, auth } from '../lib/api.js'
import { useCurrentUser } from '../lib/useCurrentUser.js'

function fmtTime(sec) {
  const m = Math.floor(sec / 60)
  const s = sec % 60
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
}

export default function AdminDashboard() {
  const [stats, setStats] = useState({ bidCount: 0, activeUsers: 0, suspiciousCount: 0 })
  const [auctions, setAuctions] = useState([])
  const [suspicious, setSuspicious] = useState([])
  const [logs, setLogs] = useState([])
  const [claims, setClaims] = useState([])
  const [lastUpdated, setLastUpdated] = useState(0)
  const [error, setError] = useState('')
  // 401(토큰 문제)과 403(권한 없음)은 대응이 전혀 다르므로 상태까지 같이 들고 있는다.
  const [errorStatus, setErrorStatus] = useState(0)
  const user = useCurrentUser()

  const loadAll = () => {
    Promise.all([
      api.adminStats(),
      api.adminAuctions(),
      api.adminSuspicious(),
      api.adminLogs(),
      api.adminClaims(),
    ])
      .then(([s, a, sus, l, c]) => {
        setStats(s)
        setAuctions(a.items)
        setSuspicious(sus.items)
        setLogs(l.items)
        setClaims(c.items)
        setLastUpdated(0)
        setError('')
        setErrorStatus(0)
      })
      .catch((e) => {
        setError(e.message)
        setErrorStatus(e.status ?? 0)
      })
  }

  useEffect(() => {
    loadAll()
    const poll = setInterval(loadAll, 5000)
    const tick = setInterval(() => setLastUpdated((s) => s + 1), 1000)
    return () => { clearInterval(poll); clearInterval(tick) }
  }, [])

  const removeAuction = async (auction) => {
    // 입찰과 이미지까지 같이 사라지고 되돌릴 수 없다. 5초 폴링이 곧 목록을
    // 새로 덮어쓰기 때문에, 확인 없이 지우면 눌린 줄이 뭐였는지도 알 수 없게 된다.
    if (!window.confirm(`"${auction.name}" 경매를 삭제할까요?\n입찰 내역과 이미지도 함께 삭제되며 되돌릴 수 없습니다.`)) {
      return
    }

    try {
      await api.adminDeleteAuction(auction.id)
      // 폴링(5초)을 기다리지 않고 즉시 목록에서 뺀다.
      setAuctions((prev) => prev.filter((a) => a.id !== auction.id))
      setError('')
    } catch (e) {
      setError(e.message)
    }
  }

  const advanceClaim = async (id) => {
    try {
      const updated = await api.advanceClaim(id)
      setClaims((prev) => prev.map((c) => (c.id === id ? updated : c)))
    } catch (e) {
      setError(e.message)
    }
  }

  const statusBadge = (s) => {
    if (s === '완료') return <span className="badge2 muted">완료</span>
    if (s === '처리중') return <span className="badge2 warn">처리중</span>
    return <span className="badge2">대기</span>
  }

  if (error) {
    // 원인마다 사용자가 해야 할 일이 다르다. 예전에는 셋 다 "관리자 계정으로
    // 로그인했는지 확인해 주세요"로 뭉뚱그려서, 권한 문제인지 토큰 문제인지
    // 화면만 보고는 구분할 수 없었다.
    const loggedIn = auth.isLoggedIn()

    let hint
    if (!loggedIn) {
      hint = <>로그인이 풀렸습니다. <Link to="/login" style={{ textDecoration: 'underline' }}>로그인 화면으로</Link></>
    } else if (errorStatus === 403) {
      hint = <>이 계정({user?.nickname ?? user?.email ?? '알 수 없음'})에는 관리자 권한이 없습니다. 관리자 계정으로 다시 로그인해 주세요.</>
    } else if (errorStatus === 401) {
      // 로그인은 되어 있는데 서버가 토큰을 거부한 경우. 대개 예전에 저장된
      // 토큰이 남아 있는 것이라 로그아웃 후 다시 로그인하면 풀린다.
      hint = <>저장된 로그인 정보가 서버에서 거부됐습니다. <Link to="/login" style={{ textDecoration: 'underline' }}>다시 로그인</Link>해 주세요.</>
    } else {
      hint = <>잠시 후 다시 시도해 주세요.</>
    }

    return (
      <div className="page-wrap">
        <div className="topbar">
          <div className="logo">CloudDuck <span style={{ fontWeight: 400, fontSize: 11, color: '#8C8C8C' }}>Admin</span></div>
        </div>
        <div style={{ padding: 24 }}>
          <p style={{ color: '#c0392b', marginBottom: 8 }}>{error}</p>
          <p style={{ fontSize: 13, color: '#8C8C8C' }}>{hint}</p>
          <p style={{ fontSize: 11, color: '#B5B5B5', marginTop: 12 }}>
            상태 {errorStatus || '—'} · 로그인 {loggedIn ? '됨' : '안 됨'}
            {user?.role ? ` · 권한 ${user.role}` : ''}
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="page-wrap">
      <div className="topbar">
        <div className="logo">CloudDuck <span style={{ fontWeight: 400, fontSize: 11, color: '#8C8C8C' }}>Admin</span></div>
        <div className="live-label"><span className="live-dot" />실시간 연결됨 · 마지막 갱신 {lastUpdated}초 전</div>
      </div>

      <div className="stat-row">
        <div className="stat">
          <div className="label">오늘 입찰 건수</div>
          <div className="value">{stats.bidCount.toLocaleString()}</div>
          <div className="delta">실시간 갱신</div>
        </div>
        <div className="stat">
          <div className="label">실시간 접속자</div>
          <div className="value">{stats.activeUsers.toLocaleString()}</div>
          <div className="delta">WebSocket 연결 수 기준</div>
        </div>
        <div className="stat">
          <div className="label">이상 입찰 탐지</div>
          <div className="value">{stats.suspiciousCount}</div>
          <div className="delta">최근 1시간</div>
        </div>
      </div>

      <div className="grid2">
        <div className="panel">
          <div className="panel-head">
            <span className="t">실시간 경매 사이트 리스트</span>
            <span className="live-label"><span className="live-dot" />LIVE</span>
          </div>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
            <thead>
              <tr>
                <th style={{ textAlign: 'left', padding: '10px 18px', fontSize: 10.5, color: '#8C8C8C', textTransform: 'uppercase', borderBottom: '1px solid #EDEDED' }}>상품명</th>
                <th style={{ textAlign: 'left', padding: '10px 18px', fontSize: 10.5, color: '#8C8C8C', textTransform: 'uppercase', borderBottom: '1px solid #EDEDED' }}>현재가</th>
                <th style={{ textAlign: 'left', padding: '10px 18px', fontSize: 10.5, color: '#8C8C8C', textTransform: 'uppercase', borderBottom: '1px solid #EDEDED' }}>남은시간</th>
                <th style={{ textAlign: 'right', padding: '10px 18px', fontSize: 10.5, color: '#8C8C8C', textTransform: 'uppercase', borderBottom: '1px solid #EDEDED' }}>관리</th>
              </tr>
            </thead>
            <tbody>
              {auctions.map((a) => (
                <tr key={a.id}>
                  <td style={{ padding: '10px 18px', borderBottom: '1px solid #F5F5F5' }}>{a.name}</td>
                  <td style={{ padding: '10px 18px', borderBottom: '1px solid #F5F5F5', fontWeight: 700 }}>{a.price.toLocaleString()}원</td>
                  <td style={{ padding: '10px 18px', borderBottom: '1px solid #F5F5F5' }}>{fmtTime(a.secondsLeft)}</td>
                  <td style={{ padding: '10px 18px', borderBottom: '1px solid #F5F5F5', textAlign: 'right' }}>
                    <button className="act-btn danger" onClick={() => removeAuction(a)}>삭제</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="panel">
          <div className="panel-head"><span className="t">이상 입찰 하이라이트</span></div>
          <div className="log-list">
            {suspicious.map((s, i) => (
              <div className="log-row" key={i}>
                <span>{s.msg}</span>
                <span className="t">{s.t}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      <div className="grid2">
        <div className="panel">
          <div className="panel-head"><span className="t">분쟁 및 클레임 관리</span></div>
          <div>
            {claims.map((c) => (
              <div className="claim-row" key={c.id}>
                <span>{c.name} <span style={{ color: '#B5B5B5' }}>· {c.user}</span></span>
                <span style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  {statusBadge(c.status)}
                  <button className="act-btn" onClick={() => advanceClaim(c.id)}>처리</button>
                </span>
              </div>
            ))}
          </div>
        </div>

        <div className="panel">
          <div className="panel-head"><span className="t">시스템 및 보안/로그</span></div>
          <div className="log-list">
            {logs.map((l, i) => (
              <div className="log-row" key={i}>
                <span>{l.msg}</span>
                <span className="t">{l.t}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      <p className="page-note">
        * 5초마다 서버에서 다시 조회합니다. 실시간 접속자 수는 실제 WebSocket 연결 수입니다.
      </p>
    </div>
  )
}
