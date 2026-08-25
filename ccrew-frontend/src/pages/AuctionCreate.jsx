import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import Nav from '../components/Nav.jsx'
import { api } from '../lib/api.js'

/**
 * datetime-local 입력이 쓰는 형식("2026-08-26T20:00")으로 바꾼다.
 * toISOString()을 쓰면 안 된다 — 그건 UTC라서 min 값이 사용자 시계와 어긋난다.
 */
function toLocalInputValue(date) {
  const pad = (n) => String(n).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}`
}

export default function AuctionCreate() {
  const navigate = useNavigate()
  // 과거 시각을 아예 고를 수 없게 한다. 서버도 검사하지만, 고르고 나서 거절당하는 것보다
  // 처음부터 못 고르는 편이 낫다. 폼이 떠 있는 동안 기준이 흔들리지 않게 한 번만 계산한다.
  const [minEndTime] = useState(() => toLocalInputValue(new Date(Date.now() + 60_000)))
  const [form, setForm] = useState({ name: '', startPrice: '', endTime: '', description: '' })
  const [imageFile, setImageFile] = useState(null)
  const [previewUrl, setPreviewUrl] = useState(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  const handleChange = (e) => {
    setForm({ ...form, [e.target.name]: e.target.value })
  }

  const handleFile = (e) => {
    const file = e.target.files?.[0] ?? null
    setImageFile(file)
    // S3에 올리기 전에 로컬에서 미리 보여준다. 업로드 성공 여부와 무관.
    setPreviewUrl(file ? URL.createObjectURL(file) : null)
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError('')
    setLoading(true)
    try {
      let images = []

      if (imageFile) {
        // 1) presigned URL 발급 2) 브라우저에서 S3로 직접 PUT
        //    파일이 백엔드 컨테이너를 거치지 않는다
        const { key } = await api.uploadImage(imageFile)
        images = [key]
      }

      // 마감시간은 반드시 여기서 절대 시각(UTC)으로 바꿔서 보낸다.
      //
      // datetime-local 의 값("2026-08-26T20:00")에는 타임존이 없다. 이걸 그대로
      // 보내면 서버 컨테이너(UTC)가 "UTC 20시"로 해석해서, 한국에서 고른 시각보다
      // 9시간 뒤로 저장된다 — 마감까지 남은 시간이 9시간씩 더 뜨던 원인이다.
      // 사용자의 시간대를 아는 건 브라우저뿐이므로 변환도 여기서 해야 한다.
      const endsAt = new Date(form.endTime)
      if (Number.isNaN(endsAt.getTime())) {
        throw new Error('마감시간을 다시 선택해 주세요')
      }

      const { id } = await api.createAuction({
        ...form,
        endTime: endsAt.toISOString(),
        images,
      })
      navigate(`/auctions/${id}`)
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="page-wrap">
      <Nav showCategories={false} />
      <form className="form-wrap" style={{ maxWidth: 420 }} onSubmit={handleSubmit}>
        {error && <div style={{ color: "#c0392b", fontSize: 13, marginBottom: 12, padding: "8px 12px", background: "#fdecea", borderRadius: 6 }}>{error}</div>}

        <label
          className="upload-box"
          htmlFor="imageUpload"
          style={
            previewUrl
              ? {
                  backgroundImage: `url(${previewUrl})`,
                  backgroundSize: 'cover',
                  backgroundPosition: 'center',
                  color: 'transparent',
                }
              : undefined
          }
        >
          {!previewUrl && '+ 상품 이미지 업로드 (S3)'}
        </label>
        <input id="imageUpload" type="file" accept="image/*" onChange={handleFile} style={{ display: 'none' }} />

        <div className="form-row">
          <label>상품명</label>
          <input name="name" placeholder="예) 원피스 루피 기어5 스케일 피규어" value={form.name} onChange={handleChange} required />
        </div>
        <div className="form-cols2">
          <div className="form-row">
            <label>시작가</label>
            <input name="startPrice" type="number" placeholder="10000" value={form.startPrice} onChange={handleChange} required />
          </div>
          <div className="form-row">
            <label>마감시간</label>
            <input name="endTime" type="datetime-local" min={minEndTime} value={form.endTime} onChange={handleChange} required />
          </div>
        </div>
        <div className="form-row">
          <label>상품 설명</label>
          <textarea name="description" placeholder="상품 상태, 특이사항 등을 입력하세요" value={form.description} onChange={handleChange} />
        </div>
        <button type="submit" className="form-btn" disabled={loading}>
          {loading ? '등록 중...' : '경매 등록하기'}
        </button>
      </form>
    </div>
  )
}
