import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import Nav from '../components/Nav.jsx'
import EventPopup from '../components/EventPopup.jsx'
import { api } from '../lib/api.js'

export default function Home() {
  const [closingSoon, setClosingSoon] = useState([])
  const [picks, setPicks] = useState([])
  const [heroImage, setHeroImage] = useState(null)

  useEffect(() => {
    // 마감 임박 = 1시간 이내 종료. 기준은 서버가 정한다(store.js CLOSING_SOON_SECONDS).
    api.listAuctions({ status: '마감임박', sort: 'endingSoon' })
      .then((d) => setClosingSoon(d.items.slice(0, 5)))
      .catch(() => {})

    api.listAuctions({ status: '진행중', sort: 'priceDesc' })
      .then((d) => {
        setPicks(d.items.slice(0, 3))

        // hero 배경은 진행 중인 경매 사진 중 하나를 무작위로 쓴다.
        // 같은 응답을 재활용해서 요청을 추가로 만들지 않는다.
        // 사진이 없는 경매가 섞여 있으므로 썸네일이 있는 것만 후보로 둔다 —
        // 안 거르면 배경이 비는 경우가 생긴다.
        const withImage = d.items.filter((i) => i.thumbnail)
        if (withImage.length > 0) {
          setHeroImage(withImage[Math.floor(Math.random() * withImage.length)].thumbnail)
        }
      })
      .catch(() => {})
  }, [])

  return (
    <div className="page-wrap">
      <EventPopup />
      <Nav showCreate showCategories={false} />

      {/* 사진이 없으면 style을 주지 않아 .hero의 기본 회색 배경이 그대로 남는다. */}
      <div
        className="hero"
        style={
          heroImage
            ? {
                backgroundImage: `url(${heroImage})`,
                backgroundSize: 'cover',
                backgroundPosition: 'center',
              }
            : undefined
        }
      >
        <div className="hero-copy">
          <div className="hero-eyebrow">Weekly Drop</div>
          <div className="hero-title">이번 주, 놓치면 후회할<br />덕후들의 피규어 경매</div>
          <Link to="/auctions" className="hero-cta">경매 둘러보기</Link>
        </div>
      </div>

      <div className="section-head">
        <div>
          <div className="section-eyebrow">Closing Soon</div>
          <div className="section-title">마감 임박 경매</div>
        </div>
        <Link to="/auctions" className="section-more">전체보기 →</Link>
      </div>

      <div className="bento">
        {closingSoon.map((item, i) => (
          <Link key={item.id} to={`/auctions/${item.id}`} className={`card ${i === 0 ? 'large' : ''}`}>
            <div
              className="cardimg"
              style={{
                backgroundImage: item.thumbnail ? `url(${item.thumbnail})` : undefined,
                backgroundSize: 'cover',
                backgroundPosition: 'center',
              }}
            >
              {item.tag && <span className="cardtag">{item.tag}</span>}
            </div>
            <div className="brand">{item.brand}</div>
            <div className="name">{item.name}</div>
            <div className="price">{item.price.toLocaleString()}원</div>
          </Link>
        ))}
      </div>

      <div className="section-head">
        <div>
          <div className="section-eyebrow">Editor's Pick</div>
          <div className="section-title">지금 주목할 아이템</div>
        </div>
      </div>
      <div className="grid3">
        {picks.map((item) => (
          <Link key={item.id} to={`/auctions/${item.id}`} className="card">
            <div
              className="cardimg"
              style={{
                backgroundImage: item.thumbnail ? `url(${item.thumbnail})` : undefined,
                backgroundSize: 'cover',
                backgroundPosition: 'center',
              }}
            />
            <div className="brand">{item.brand}</div>
            <div className="name">{item.name}</div>
            <div className="price">{item.price.toLocaleString()}원</div>
          </Link>
        ))}
      </div>
    </div>
  )
}
