import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import Nav from '../components/Nav.jsx'
import { api } from '../lib/api.js'

const filters = ['진행중', '마감임박', '종료']

export default function AuctionList() {
  const [searchParams] = useSearchParams()
  const cat = searchParams.get('cat') ?? undefined

  const [activeFilter, setActiveFilter] = useState('진행중')
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    setLoading(true)
    api.listAuctions({ status: activeFilter, cat, sort: 'endingSoon' })
      .then((d) => setItems(d.items))
      .catch(() => setItems([]))
      .finally(() => setLoading(false))
  }, [activeFilter, cat])

  return (
    <div className="page-wrap">
      <Nav showCreate />
      <div className="filters">
        {filters.map((f) => (
          <button
            key={f}
            className={`chip ${activeFilter === f ? 'active' : ''}`}
            onClick={() => setActiveFilter(f)}
          >
            {f}
          </button>
        ))}
        <button className="chip">정렬: 마감순 ▾</button>
      </div>

      {loading ? (
        <p style={{ padding: 24, color: '#8C8C8C' }}>불러오는 중...</p>
      ) : (
        <div className="grid3" style={{ paddingTop: 24 }}>
          {items.map((item) => (
            <Link key={item.id} to={`/auctions/${item.id}`} className="card">
              <div
                className="cardimg"
                style={{
                  aspectRatio: '3 / 4',
                  height: 'auto',
                  backgroundImage: item.thumbnail ? `url(${item.thumbnail})` : undefined,
                  backgroundSize: 'cover',
                  backgroundPosition: 'center',
                }}
              />
              <div className="brand">{item.brand}</div>
              <div className="name">{item.name}</div>
              <div className="price">{item.price.toLocaleString()}원</div>
              <div className="badge">{item.ended ? '종료' : `${Math.floor(item.secondsLeft / 60)}분 남음`}</div>
            </Link>
          ))}
        </div>
      )}
    </div>
  )
}
