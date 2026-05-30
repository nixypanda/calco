import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/AuthContext";

export function UserHome() {
  const navigate = useNavigate();
  const { identity, profile, logout } = useAuth();

  return (
    <div className="user-home">
      <header>
        <h1>CalCo</h1>
        <div className="header-right">
          <span>
            Welcome,{" "}
            <strong>{profile?.display_name ?? identity?.username}</strong>
          </span>
          <button onClick={logout}>Logout</button>
        </div>
      </header>
      <main>
        <p className="placeholder">Your food diary will appear here.</p>
        <div className="nav-links">
          <button
            className="btn-primary"
            onClick={() => navigate("/search")}
          >
            Search Foods
          </button>
          <button
            className="btn-secondary"
            onClick={() => navigate("/foods/custom/new")}
          >
            Create Custom Food
          </button>
        </div>
      </main>
    </div>
  );
}
