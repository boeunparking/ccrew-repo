import { useState } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import Nav from '../components/Nav.jsx'
import SocialLogin from '../components/SocialLogin.jsx'
import { signUp, confirmSignUp, resendConfirmationCode } from '../lib/cognito.js'

const errorBox = {
  color: '#c0392b',
  fontSize: 13,
  marginBottom: 12,
  padding: '8px 12px',
  background: '#fdecea',
  borderRadius: 6,
}

const noticeBox = {
  color: '#2c6e49',
  fontSize: 13,
  marginBottom: 12,
  padding: '8px 12px',
  background: '#eaf6ef',
  borderRadius: 6,
}

/**
 * 회원가입.
 *
 * Cognito로 넘어오면서 단계가 하나 늘었다 — User Pool이 email을
 * auto_verified_attributes로 잡고 있어서(terraform/cognito.tf) 가입 직후 계정은
 * 아직 로그인할 수 없는 상태이고, 메일로 온 인증코드를 확인해야 비로소 쓸 수 있다.
 * 그래서 이 화면은 'form'(가입) → 'confirm'(코드 확인) 두 단계로 동작한다.
 *
 * 로그인 화면에서 미인증 계정으로 로그인을 시도한 경우에도 여기로 보내진다
 * (location.state.pendingEmail) — 그때는 코드 확인 단계부터 시작한다.
 */
export default function SignUp() {
  const navigate = useNavigate()
  const { state } = useLocation()

  const pendingEmail = state?.pendingEmail ?? ''

  const [step, setStep] = useState(pendingEmail ? 'confirm' : 'form')
  const [form, setForm] = useState({
    email: pendingEmail,
    password: '',
    passwordConfirm: '',
  })
  const [code, setCode] = useState('')
  const [error, setError] = useState('')
  const [notice, setNotice] = useState(
    pendingEmail ? '이메일 인증이 끝나지 않은 계정입니다. 메일로 받은 인증코드를 입력해 주세요' : ''
  )
  const [loading, setLoading] = useState(false)

  const handleChange = (e) => {
    setForm({ ...form, [e.target.name]: e.target.value })
  }

  const handleSignUp = async (e) => {
    e.preventDefault()
    setError('')
    setNotice('')

    // Cognito는 비밀번호 확인 같은 걸 모른다 — 두 번 입력받는 건 우리 화면의 장치이므로
    // 검증도 여기서 한다. (길이/문자 조건은 User Pool의 password_policy가 본다)
    if (form.password !== form.passwordConfirm) {
      setError('비밀번호가 서로 다릅니다')
      return
    }

    setLoading(true)
    try {
      const { needsConfirmation } = await signUp(form)

      if (!needsConfirmation) {
        // 지금 설정에선 오지 않는 경로지만, 정책이 바뀌어 자동 확인되면 그대로 로그인시킨다.
        navigate('/login')
        return
      }

      setStep('confirm')
      setNotice(`${form.email} 으로 인증코드를 보냈습니다`)
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const handleConfirm = async (e) => {
    e.preventDefault()
    setError('')
    setNotice('')
    setLoading(true)
    try {
      await confirmSignUp({ email: form.email, code: code.trim() })
      navigate('/login', { state: { justConfirmed: true } })
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const handleResend = async () => {
    setError('')
    setNotice('')
    setLoading(true)
    try {
      await resendConfirmationCode(form.email)
      setNotice('인증코드를 다시 보냈습니다')
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  if (step === 'confirm') {
    return (
      <div className="page-wrap">
        <Nav showCategories={false} />
        <form className="form-wrap" onSubmit={handleConfirm}>
          {error && <div style={errorBox}>{error}</div>}
          {notice && <div style={noticeBox}>{notice}</div>}

          <div className="form-row">
            <label>이메일</label>
            <input
              name="email"
              type="email"
              value={form.email}
              onChange={handleChange}
              required
              // 코드를 받은 주소와 다른 주소로 확인하면 항상 실패한다.
              readOnly={Boolean(pendingEmail)}
            />
          </div>
          <div className="form-row">
            <label>인증코드</label>
            <input
              name="code"
              type="text"
              inputMode="numeric"
              autoComplete="one-time-code"
              placeholder="메일로 받은 6자리 숫자"
              value={code}
              onChange={(e) => setCode(e.target.value)}
              required
            />
          </div>

          <button type="submit" className="form-btn" disabled={loading}>
            {loading ? '확인 중...' : '인증 완료'}
          </button>

          <div className="form-link">
            코드를 못 받으셨나요?{' '}
            <button
              type="button"
              onClick={handleResend}
              disabled={loading}
              style={{
                background: 'none',
                border: 'none',
                padding: 0,
                font: 'inherit',
                color: '#141414',
                textDecoration: 'underline',
                cursor: 'pointer',
              }}
            >
              다시 보내기
            </button>
          </div>
        </form>
      </div>
    )
  }

  return (
    <div className="page-wrap">
      <Nav showCategories={false} />
      <form className="form-wrap" onSubmit={handleSignUp}>
        {error && <div style={errorBox}>{error}</div>}
        {notice && <div style={noticeBox}>{notice}</div>}

        <div className="form-row">
          <label>이메일</label>
          <input name="email" type="email" placeholder="example@email.com" value={form.email} onChange={handleChange} required />
        </div>
        <div className="form-row">
          <label>비밀번호</label>
          <input name="password" type="password" placeholder="8자 이상, 영문 소문자와 숫자 포함" value={form.password} onChange={handleChange} required />
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
