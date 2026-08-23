import { useEffect, useRef, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import Nav from '../components/Nav.jsx'
import { completeGoogleLogin } from '../lib/cognito.js'
import { refreshCurrentUser } from '../lib/useCurrentUser.js'

/**
 * 구글 로그인이 끝나고 Cognito가 브라우저를 돌려보내는 곳.
 *
 * 예전에는 우리 백엔드가 토큰을 만들어 URL 프래그먼트(#token=...)에 실어 보냈다.
 * 지금 돌아오는 건 토큰이 아니라 authorization code다 — 그 자체로는 로그인이 안 되고,
 * 이 페이지가 PKCE verifier와 함께 Cognito 토큰 엔드포인트에 제출해야 토큰이 나온다
 * (lib/cognito.js의 completeGoogleLogin).
 */

// Cognito가 code 대신 error로 돌려보내는 경우들.
const MESSAGES = {
  access_denied: '구글 로그인을 취소했습니다',
  invalid_request: '로그인 요청이 올바르지 않습니다',
  server_error: '로그인 처리 중 오류가 발생했습니다. 잠시 후 다시 시도해 주세요',
  temporarily_unavailable: '잠시 후 다시 시도해 주세요',
}

export default function OAuthCallback() {
  const navigate = useNavigate()
  const [error, setError] = useState('')

  // StrictMode는 개발 중 effect를 두 번 돌린다. code는 일회용이라 두 번째 교환은
  // 반드시 invalid_grant로 실패한다 — 그러면 로그인은 됐는데 에러가 뜬다.
  const handled = useRef(false)

  useEffect(() => {
    if (handled.current) return
    handled.current = true

    const params = new URLSearchParams(window.location.search)

    // 주소창과 히스토리에서 code를 즉시 지운다.
    // 남겨두면 뒤로 가기나 주소 복사로 새어 나가고, 재방문 시 만료된 code로 또 실패한다.
    window.history.replaceState(null, '', window.location.pathname)

    const failure = params.get('error')
    if (failure) {
      setError(MESSAGES[failure] ?? '로그인에 실패했습니다')
      return
    }

    const code = params.get('code')
    if (!code) {
      setError('로그인 정보를 받지 못했습니다')
      return
    }

    completeGoogleLogin(code)
      .then(({ redirectPath }) => {
        refreshCurrentUser()
        navigate(redirectPath || '/', { replace: true })
      })
      .catch((e) => setError(e.message))
  }, [navigate])

  return (
    <div className="page-wrap">
      <Nav showCategories={false} />
      <div className="form-wrap" style={{ textAlign: 'center', paddingTop: 60 }}>
        {error ? (
          <>
            <div
              style={{
                color: '#c0392b',
                fontSize: 13,
                marginBottom: 16,
                padding: '8px 12px',
                background: '#fdecea',
                borderRadius: 6,
              }}
            >
              {error}
            </div>
            <Link to="/login" style={{ fontSize: 12, color: '#141414', textDecoration: 'underline' }}>
              로그인 화면으로
            </Link>
          </>
        ) : (
          <div style={{ fontSize: 13, color: '#8a8a8a' }}>로그인 중...</div>
        )}
      </div>
    </div>
  )
}
