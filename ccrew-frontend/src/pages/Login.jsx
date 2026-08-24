import { useState } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import Nav from '../components/Nav.jsx'
import SocialLogin from '../components/SocialLogin.jsx'
import { login } from '../lib/cognito.js'
import { refreshCurrentUser } from '../lib/useCurrentUser.js'

export default function Login() {
  const navigate = useNavigate()
  const { state } = useLocation()
  const [form, setForm] = useState({ email: '', password: '' })
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  // 메일 인증을 막 끝내고 넘어온 경우. 인증 화면이 조용히 사라지면 사용자는
  // 인증이 된 건지 알 수 없다.
  const notice = state?.justConfirmed ? '이메일 인증이 완료됐습니다. 로그인해 주세요' : ''

  const handleChange = (e) => {
    setForm({ ...form, [e.target.name]: e.target.value })
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError('')
    setLoading(true)
    try {
      // 백엔드를 거치지 않는다 — 브라우저가 Cognito와 SRP로 직접 인증하고,
      // 성공하면 토큰 저장까지 login()이 해준다.
      await login(form)
      // Nav가 즉시 로그인 상태로 바뀌도록 캐시를 버리고 다시 확인한다.
      refreshCurrentUser()
      navigate('/')
    } catch (err) {
      // 가입은 했는데 메일 인증을 안 끝낸 계정. 여기서 막다른 길로 두면
      // 사용자는 비밀번호가 틀린 줄 알고 계속 다시 친다 — 인증 화면으로 넘긴다.
      if (err.code === 'UserNotConfirmedException') {
        navigate('/signup', { state: { pendingEmail: form.email } })
        return
      }
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
        {notice && !error && <div style={{ color: "#2c6e49", fontSize: 13, marginBottom: 12, padding: "8px 12px", background: "#eaf6ef", borderRadius: 6 }}>{notice}</div>}
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
