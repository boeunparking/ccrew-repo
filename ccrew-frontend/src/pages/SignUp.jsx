import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import Nav from '../components/Nav.jsx'
import SocialLogin from '../components/SocialLogin.jsx'
import { api } from '../lib/api.js'

export default function SignUp() {
  const navigate = useNavigate()
  const [form, setForm] = useState({ email: '', password: '', passwordConfirm: '' })
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  const handleChange = (e) => {
    setForm({ ...form, [e.target.name]: e.target.value })
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError('')
    setLoading(true)
    try {
      await api.signup(form)
      navigate('/login')
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="page-wrap">
      <Nav showCategories={false} />
      <form className="form-wrap" onSubmit={handleSubmit}>
        {error && <div style={{ color: "#c0392b", fontSize: 13, marginBottom: 12, padding: "8px 12px", background: "#fdecea", borderRadius: 6 }}>{error}</div>}
        <div className="form-row">
          <label>이메일</label>
          <input name="email" type="email" placeholder="example@email.com" value={form.email} onChange={handleChange} required />
        </div>
        <div className="form-row">
          <label>비밀번호</label>
          <input name="password" type="password" placeholder="8자 이상" value={form.password} onChange={handleChange} required />
        </div>
        <div className="form-row">
          <label>비밀번호 확인</label>
          <input name="passwordConfirm" type="password" placeholder="비밀번호 재입력" value={form.passwordConfirm} onChange={handleChange} required />
        </div>
        <button type="submit" className="form-btn" disabled={loading}>
          {loading ? '가입 중...' : '회원가입'}
        </button>
        {/* 소셜로 들어오면 회원가입 폼 자체를 건너뛴다 — 첫 로그인에 계정이 생긴다 */}
        <SocialLogin redirectPath="/" />
        <div className="form-link">
          이미 계정이 있으신가요? <Link to="/login" style={{ color: '#141414', textDecoration: 'underline' }}>로그인</Link>
        </div>
      </form>
    </div>
  )
}
