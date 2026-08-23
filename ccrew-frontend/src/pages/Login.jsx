import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import Nav from '../components/Nav.jsx'
import SocialLogin from '../components/SocialLogin.jsx'
import { api } from '../lib/api.js'

export default function Login() {
  const navigate = useNavigate()
  const [form, setForm] = useState({ email: '', password: '' })
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
      // api.login이 성공하면 토큰을 localStorage에 저장까지 해준다
      await api.login(form)
      navigate('/')
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
          <input name="password" type="password" placeholder="비밀번호 입력" value={form.password} onChange={handleChange} required />
        </div>
        <button type="submit" className="form-btn" disabled={loading}>
          {loading ? '로그인 중...' : '로그인'}
        </button>
        <SocialLogin redirectPath="/" />
        <div className="form-link">
          계정이 없으신가요? <Link to="/signup" style={{ color: '#141414', textDecoration: 'underline' }}>회원가입</Link>
        </div>
      </form>
    </div>
  )
}
