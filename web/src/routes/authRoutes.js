/**
 * 인증 관련 API 엔드포인트.
 *   POST /auth/signup
 *   POST /auth/login
 *   GET  /auth/me
 *   /auth/oauth/*  — 소셜 로그인 (routes/oauthRoutes.js)
 *
 * 토큰 생성/검증 로직 자체는 src/authMiddleware.js 에 있다.
 */
import { Router } from "express";
import bcrypt from "bcryptjs";
import crypto from "crypto";
import { findUserByEmail, createUser, listIdentities } from "../store.js";
import { signToken, requireAuth } from "../authMiddleware.js";
import oauthRoutes from "./oauthRoutes.js";

const router = Router();

// /auth/oauth/google, /auth/oauth/kakao/callback ...
router.use("/oauth", oauthRoutes);

// SignUp.jsx: { email, password, passwordConfirm }
router.post("/signup", async (req, res) => {
  const { email, password, passwordConfirm } = req.body ?? {};

  if (!email || !password) {
    return res.status(400).json({ error: "이메일과 비밀번호를 입력해 주세요" });
  }
  if (password.length < 8) {
    return res.status(400).json({ error: "비밀번호는 8자 이상이어야 합니다" });
  }
  if (password !== passwordConfirm) {
    return res.status(400).json({ error: "비밀번호가 서로 다릅니다" });
  }
  if (await findUserByEmail(email)) {
    return res.status(409).json({ error: "이미 가입된 이메일입니다" });
  }

  const user = {
    id: crypto.randomUUID(),
    email,
    passwordHash: await bcrypt.hash(password, 10),
    nickname: email.split("@")[0],
    role: "user",
  };
  await createUser(user);

  res
    .status(201)
    .json({ id: user.id, email: user.email, nickname: user.nickname });
});

// Login.jsx: { email, password }
router.post("/login", async (req, res) => {
  const { email, password } = req.body ?? {};
  const user = await findUserByEmail(email);

  // 계정 존재 여부를 노출하지 않도록 같은 메시지를 쓴다
  const fail = () =>
    res.status(401).json({ error: "이메일 또는 비밀번호가 올바르지 않습니다" });

  if (!user) return fail();
  // 소셜로만 가입한 계정은 password_hash가 null이다.
  // bcrypt.compare에 null을 넘기면 예외가 나므로 먼저 걸러낸다.
  if (!user.passwordHash) {
    return res.status(401).json({
      error: "소셜 계정으로 가입한 이메일입니다. 소셜 로그인을 이용해 주세요",
    });
  }
  if (!(await bcrypt.compare(password ?? "", user.passwordHash))) return fail();

  res.json({
    token: signToken(user),
    user: {
      id: user.id,
      email: user.email,
      nickname: user.nickname,
      role: user.role,
    },
  });
});

router.get("/me", requireAuth, async (req, res) => {
  res.json({
    id: req.user.sub,
    email: req.user.email,
    nickname: req.user.nickname,
    role: req.user.role,
    // 연결된 소셜 계정. 비밀번호로 가입한 사용자는 빈 배열이다.
    identities: await listIdentities(req.user.sub),
  });
});

export default router;
