import { useEffect } from "react";
import { Routes, Route, useLocation } from "react-router-dom";
import SignUp from "./pages/SignUp.jsx";
import Login from "./pages/Login.jsx";
import OAuthCallback from "./pages/OAuthCallback.jsx";
import Home from "./pages/Home.jsx";
import AuctionList from "./pages/AuctionList.jsx";
import AuctionDetail from "./pages/AuctionDetail.jsx";
import AuctionCreate from "./pages/AuctionCreate.jsx";
import BidHistory from "./pages/BidHistory.jsx";
import MyPage from "./pages/MyPage.jsx";
import AdminDashboard from "./pages/AdminDashboard.jsx";

function ScrollToTop() {
  const { pathname } = useLocation();

  useEffect(() => {
    window.scrollTo(0, 0);
  }, [pathname]);

  return null;
}

export default function App() {
  return (
    <>
      <ScrollToTop />
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/signup" element={<SignUp />} />
        <Route path="/login" element={<Login />} />
        {/* 소셜 로그인이 끝난 뒤 백엔드가 돌려보내는 경로 */}
        <Route path="/oauth/callback" element={<OAuthCallback />} />
        <Route path="/auctions" element={<AuctionList />} />
        <Route path="/auctions/new" element={<AuctionCreate />} />
        <Route path="/auctions/:id" element={<AuctionDetail />} />
        <Route path="/bids" element={<BidHistory />} />
        <Route path="/mypage" element={<MyPage />} />
        <Route path="/admin" element={<AdminDashboard />} />
      </Routes>
    </>
  );
}
