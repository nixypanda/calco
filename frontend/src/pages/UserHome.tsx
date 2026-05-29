import { useAuth } from "../hooks/AuthContext";

export function UserHome() {
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
      </main>
    </div>
  );
}
