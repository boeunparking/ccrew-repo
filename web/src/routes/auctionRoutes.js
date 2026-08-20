import { Router } from "express";
import crypto from "crypto";
import {
  listAuctions,
  getAuctionById,
  createAuction,
  getBidsForAuction,
  secondsLeft,
  isEnded,
  toListItem,
  toImagePath,
} from "../store.js";
import { requireAuth } from "../authMiddleware.js";
import redis, { initAuctionPrice } from "../valkey.js";

const router = Router();

// AuctionList.jsx / Home.jsx
// GET /auctions?status=진행중&cat=scale&sort=endingSoon
router.get("/", async (req, res) => {
  const { status = "진행중", cat, sort = "endingSoon" } = req.query;

  let list = await listAuctions();

  if (cat) list = list.filter((a) => a.category === cat);

  if (status === "진행중") list = list.filter((a) => !isEnded(a));
  else if (status === "종료") list = list.filter((a) => isEnded(a));
  else if (status === "마감임박")
    list = list.filter((a) => !isEnded(a) && secondsLeft(a) <= 600);

  if (sort === "endingSoon")
    list.sort((a, b) => secondsLeft(a) - secondsLeft(b));
  else if (sort === "priceDesc")
    list.sort((a, b) => b.currentPrice - a.currentPrice);
  else if (sort === "priceAsc")
    list.sort((a, b) => a.currentPrice - b.currentPrice);

  res.json({ items: list.map(toListItem) });
});

// AuctionDetail.jsx
router.get("/:id", async (req, res) => {
  const a = await getAuctionById(req.params.id);
  if (!a) return res.status(404).json({ error: "존재하지 않는 경매입니다" });

  const history = await getBidsForAuction(a.id);
  // 서로 다른 입찰자 수
  const bidderCount = new Set(history.map((b) => b.userId)).size;

  res.json({
    id: a.id,
    name: a.name,
    brand: a.brand,
    seller: a.seller,
    description: a.description,
    images: a.images.map(toImagePath),
    startPrice: a.startPrice,
    currentPrice: a.currentPrice,
    secondsLeft: secondsLeft(a),
    ended: isEnded(a),
    bidderCount,
    // 화면에는 최신 순으로 노출
    history: history.map((b) => ({
      user: b.nickname,
      price: b.price,
      at: b.createdAt,
    })),
  });
});

// AuctionDetail.jsx 하단 "함께 보면 좋은 경매"
router.get("/:id/related", async (req, res) => {
  const a = await getAuctionById(req.params.id);
  if (!a) return res.status(404).json({ error: "존재하지 않는 경매입니다" });

  const all = await listAuctions();
  const related = all
    .filter((x) => x.id !== a.id && x.category === a.category && !isEnded(x))
    .slice(0, 3)
    .map(toListItem);

  res.json({ items: related });
});

// AuctionCreate.jsx
// 이미지는 /uploads/presign으로 S3에 직접 올린 뒤 그 key를 images에 넣어 보낸다
router.post("/", requireAuth, async (req, res) => {
  const {
    name,
    startPrice,
    endTime,
    description,
    images = [],
  } = req.body ?? {};

  if (!name || !startPrice || !endTime) {
    return res
      .status(400)
      .json({ error: "상품명, 시작가, 마감시간은 필수입니다" });
  }

  const price = Number(startPrice);
  if (!Number.isFinite(price) || price <= 0) {
    return res.status(400).json({ error: "시작가는 0보다 큰 숫자여야 합니다" });
  }

  const endsAt = new Date(endTime);
  if (Number.isNaN(endsAt.getTime()) || endsAt.getTime() <= Date.now()) {
    return res
      .status(400)
      .json({ error: "마감시간은 현재보다 이후여야 합니다" });
  }

  const auction = {
    id: crypto.randomUUID(),
    name,
    brand: req.body.brand ?? "기타",
    category: req.body.category ?? "etc",
    startPrice: price,
    currentPrice: price,
    endsAt: endsAt.toISOString(),
    sellerId: req.user.sub,
    tag: "NEW",
    description: description ?? "",
    images,
  };

  await createAuction(auction);

  // Valkey에 시작가를 심어둔다 — 이게 없으면 첫 입찰 시 bid.lua가
  // "AUCTION_NOT_FOUND"로 실패한다.
  await initAuctionPrice(auction.id, price);

  // 워커(batch)가 마감된 경매를 찾을 수 있게 Valkey에도 등록한다.
  // RDS는 워커가 직접 조회하지 않으므로(worker.js는 Valkey만 본다) 여기 등록이 필수다.
  // 실패해도 경매 등록 자체는 이미 RDS에 성공했으니 응답을 막지 않는다.
  await Promise.all([
    redis.zadd("auctions:open", endsAt.getTime(), auction.id),
    redis.hset(`auction:${auction.id}:meta`, "name", auction.name),
  ]).catch((e) => console.error("[auction] 워커용 Valkey 등록 실패:", e.message));

  res.status(201).json({ id: auction.id });
});

export default router;
