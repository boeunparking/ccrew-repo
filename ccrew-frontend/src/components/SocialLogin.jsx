import { useEffect, useState } from 'react'
import { api } from '../lib/api.js'

// 브랜드 가이드상 각 버튼 색은 고정이다 (카카오 #FEE500, 구글은 흰 바탕 + 회색 테두리).
const STYLE = {
  google: { background: '#fff', color: '#3c4043', border: '1px solid #dadce0' },
  kakao: { background: '#FEE500', color: '#191600', border: 'none' },
}

const LABEL = {
  google: 'Google로 계속하기',
  kakao: '카카오로 계속하기',
}

/**
 * 소셜 로그인 버튼 묶음.
 *
 * 어떤 버튼을 그릴지는 백엔드가 정한다 — 환경변수에 키가 안 들어간 공급자는
 * 목록에서 빠지므로, 눌렀는데 404가 나는 버튼이 화면에 남지 않는다.
 *
 * @param {string} redirectPath 로그인 후 돌아갈 프론트 내부 경로
 */
export default function SocialLogin({ redirectPath = '/' }) {
  const [providers, setProviders] = useState([])
  const [error, setError] = useState('')

  useEffect(() => {
    api
      .oauthProviders()
      .then((d) => setProviders(d.providers ?? []))
      .catch((e) => setError(e.message))
  }, [])

  // 서버에 못 닿은 것과 "켜진 공급자가 없는 것"은 다르다.
  // 전자를 조용히 감추면 소셜 로그인 기능이 아예 없는 것처럼 보여서 원인을 못 찾는다.
  if (error) {
    return (
      <div style={{ marginTop: 22, fontSize: 12, color: '#8a8a8a', textAlign: 'center', lineHeight: 1.6 }}>
        소셜 로그인 사용 가능 여부를 확인하지 못했습니다.
        <br />
        <span style={{ fontSize: 11 }}>{error}</span>
      </div>
    )
  }

  // 여기는 서버가 "켜진 공급자 없음"이라고 답한 경우다. 이땐 조용히 감추는 게 맞다.
  if (!providers.length) return null

  // fetch가 아니라 페이지 이동이다 — 백엔드가 302로 동의 화면에 넘긴다.
  const start = (provider) => {
    window.location.href = api.oauthStartUrl(provider, redirectPath)
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

      {providers.map((p) => (
        <button
          key={p}
          type="button"
          onClick={() => start(p)}
          style={{
            width: '100%',
            padding: 12,
            marginBottom: 8,
            fontSize: 12.5,
            fontWeight: 600,
            fontFamily: 'inherit',
            cursor: 'pointer',
            ...(STYLE[p] ?? STYLE.google),
          }}
        >
          {LABEL[p] ?? `${p}로 계속하기`}
        </button>
      ))}
    </div>
  )
}
