import { useState } from 'react'
import { startGoogleLogin } from '../lib/cognito.js'
import { IS_COGNITO_CONFIGURED } from '../lib/config.js'

// 브랜드 가이드상 구글 버튼은 흰 바탕 + 회색 테두리로 고정이다.
const GOOGLE_STYLE = {
  background: '#fff',
  color: '#3c4043',
  border: '1px solid #dadce0',
}

/**
 * 소셜 로그인 버튼.
 *
 * 예전에는 백엔드에 `/auth/oauth/providers`를 물어 어떤 버튼을 그릴지 정했다.
 * 지금은 공급자가 Cognito User Pool에 붙어 있고(terraform/cognito.tf) 구글 하나뿐이라
 * 물어볼 것이 없다. 카카오는 Cognito가 기본 지원하는 IdP가 아니라 제거됐다.
 *
 * @param {string} redirectPath 로그인 후 돌아갈 프론트 내부 경로
 */
export default function SocialLogin({ redirectPath = '/' }) {
  const [error, setError] = useState('')

  // 설정이 비어 있으면 눌러도 Cognito 주소를 만들 수 없다.
  // 버튼을 감추는 것과 "구글 로그인이 원래 없는 것"은 화면에서 구분이 안 되므로,
  // 원인을 적어 둔다 — 사용자가 다시 눌러서 풀릴 문제가 아니다.
  if (!IS_COGNITO_CONFIGURED) {
    return (
      <div style={{ marginTop: 22, fontSize: 12, color: '#8a8a8a', textAlign: 'center', lineHeight: 1.6 }}>
        구글 로그인을 사용할 수 없습니다.
        <br />
        <span style={{ fontSize: 11 }}>로그인 설정(Cognito)이 배포되지 않았습니다</span>
      </div>
    )
  }

  const start = async () => {
    setError('')
    try {
      // fetch가 아니라 페이지 이동이다 — 구글 동의 화면은 XHR로 못 띄운다(CORS).
      await startGoogleLogin(redirectPath)
    } catch (e) {
      setError(e.message)
    }
  }

  return (
    <div style={{ marginTop: 22 }}>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          color: '#8a8a8a',
          fontSize: 10.5,
          letterSpacing: '0.06em',
          marginBottom: 14,
        }}
      >
        <span style={{ flex: 1, height: 1, background: '#e5e5e5' }} />
        SNS 계정으로 로그인
        <span style={{ flex: 1, height: 1, background: '#e5e5e5' }} />
      </div>

      <button
        type="button"
        onClick={start}
        style={{
          width: '100%',
          padding: 12,
          marginBottom: 8,
          fontSize: 12.5,
          fontWeight: 600,
          fontFamily: 'inherit',
          cursor: 'pointer',
          ...GOOGLE_STYLE,
        }}
      >
        Google로 계속하기
      </button>

      {error && (
        <div style={{ fontSize: 11.5, color: '#c0392b', textAlign: 'center', marginTop: 6 }}>
          {error}
        </div>
      )}
    </div>
  )
}
