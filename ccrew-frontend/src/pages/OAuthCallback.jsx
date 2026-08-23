import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import Nav from '../components/Nav.jsx'
import { auth } from '../lib/api.js'

/**
 * 소셜 로그인이 끝나고 백엔드가 브라우저를 돌려보내는 곳.
 *
 * 백엔드는 토큰을 쿼리스트링이 아니라 URL 프래그먼트(#token=...)에 실어 보낸다.
 * 프래그먼트는 서버로 전송되지 않아서 ALB/CloudFront 액세스 로그나 Referer에
 * 토큰이 남지 않는다. 대신 읽는 건 이 페이지의 몫이다.
 */

const MESSAGES = {
  denied: '소셜 로그인을 취소했습니다',
  invalid_state: '로그인 요청이 만료됐습니다. 다시 시도해 주세요',
  invalid_request: '로그인 정보가 올바르지 않습니다',
  exchange_failed: '소셜 계정 확인에 실패했습니다. 잠시 후 다시 시도해 주세요',
}

export default function OAuthCallback() {
  const navigate = useNavigate()
  const [error, setError] = useState('')

  useEffect(() => {
    const params = new URLSearchParams(window.location.hash.slice(1))

    // 주소창과 히스토리에서 토큰을 즉시 지운다.
    // 이걸 안 하면 뒤로 가기나 주소 복사로 토큰이 그대로 새어 나간다.
    window.history.replaceState(null, '', window.location.pathname)

    const failure = params.get('error')
    if (failure) {
      setError(MESSAGES[failure] ?? '로그인에 실패했습니다')
      return
    }

    const token = params.get('token')
    if (!token) {
      setError('로그인 정보를 받지 못했습니다')
      return
    }

    auth.set(token)
    navigate(params.get('redirect') || '/', { replace: true })
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
