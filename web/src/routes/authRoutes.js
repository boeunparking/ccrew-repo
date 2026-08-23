/**
 * 인증 관련 API 엔드포인트.
 *   GET /auth/me
 *
 * 회원가입/로그인/소셜 로그인은 이 서버가 하지 않는다 — 프론트가 Cognito를
 * 직접 호출해서 ID 토큰을 받아온다. 이 서버는 그 토큰을 검증만 한다
 * (토큰 검증 로직 자체는 src/authMiddleware.js 에 있다).
 */
import { Router } from "express";
import { requireAuth } from "../authMiddleware.js";

const router = Router();

router.get("/me", requireAuth, async (req, res) => {
  res.json({
    id: req.user.sub,
    email: req.user.email,
    nickname: req.user.nickname,
    groups: req.user.groups,
  });
});

export default router;
