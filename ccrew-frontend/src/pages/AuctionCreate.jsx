import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import Nav from '../components/Nav.jsx'
import { api } from '../lib/api.js'

export default function AuctionCreate() {
  const navigate = useNavigate()
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

      const { id } = await api.createAuction({ ...form, images })
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
            <input name="endTime" type="datetime-local" value={form.endTime} onChange={handleChange} required />
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
