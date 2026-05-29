import { useState, useEffect, type FormEvent } from "react";
import { useAuth } from "../hooks/AuthContext";
import {
  listUsers,
  createUser,
  resetPassword,
  disableUser,
  enableUser,
} from "../api/admin";
import type { UserItem } from "../api/admin";

export function AdminDashboard() {
  const { identity, logout } = useAuth();
  const [users, setUsers] = useState<UserItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const [showCreate, setShowCreate] = useState(false);
  const [newUser, setNewUser] = useState({
    username: "",
    display_name: "",
    initial_password: "",
  });

  const [resetPass, setResetPass] = useState<{
    userId: string;
    password: string;
  } | null>(null);

  const fetchUsers = async () => {
    try {
      const resp = await listUsers();
      setUsers(resp.users);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to load users");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchUsers();
  }, []);

  const handleCreate = async (e: FormEvent) => {
    e.preventDefault();
    setError("");
    try {
      await createUser(newUser);
      setShowCreate(false);
      setNewUser({ username: "", display_name: "", initial_password: "" });
      await fetchUsers();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to create user");
    }
  };

  const handleResetPassword = async (userId: string) => {
    if (!resetPass || resetPass.userId !== userId) return;
    setError("");
    try {
      await resetPassword(userId, resetPass.password);
      setResetPass(null);
    } catch (err: unknown) {
      setError(
        err instanceof Error ? err.message : "Failed to reset password",
      );
    }
  };

  const handleDisable = async (userId: string) => {
    setError("");
    try {
      await disableUser(userId);
      await fetchUsers();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to disable user");
    }
  };

  const handleEnable = async (userId: string) => {
    setError("");
    try {
      await enableUser(userId);
      await fetchUsers();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to enable user");
    }
  };

  return (
    <div className="admin-page">
      <header>
        <h1>Admin Dashboard</h1>
        <div className="header-right">
          <span>Logged in as <strong>{identity?.username}</strong></span>
          <button onClick={logout}>Logout</button>
        </div>
      </header>

      {error && <p className="error">{error}</p>}

      <section>
        <div className="section-header">
          <h2>Users</h2>
          <button onClick={() => setShowCreate(!showCreate)}>
            {showCreate ? "Cancel" : "Create User"}
          </button>
        </div>

        {showCreate && (
          <form className="create-user-form" onSubmit={handleCreate}>
            <input
              placeholder="Username"
              value={newUser.username}
              onChange={(e) =>
                setNewUser({ ...newUser, username: e.target.value })
              }
            />
            <input
              placeholder="Display Name"
              value={newUser.display_name}
              onChange={(e) =>
                setNewUser({ ...newUser, display_name: e.target.value })
              }
            />
            <input
              type="password"
              placeholder="Initial Password"
              value={newUser.initial_password}
              onChange={(e) =>
                setNewUser({ ...newUser, initial_password: e.target.value })
              }
            />
            <button type="submit">Save</button>
          </form>
        )}

        {loading ? (
          <p>Loading users...</p>
        ) : users.length === 0 ? (
          <p>No users yet.</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Username</th>
                <th>Display Name</th>
                <th>Status</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {users.map((user) => (
                <tr key={user.id}>
                  <td>{user.username}</td>
                  <td>{user.display_name}</td>
                  <td>{user.status}</td>
                  <td className="actions">
                    <button
                      onClick={() =>
                        setResetPass(
                          resetPass?.userId === user.id
                            ? null
                            : { userId: user.id, password: "" },
                        )
                      }
                    >
                      Reset Password
                    </button>
                    {user.status === "active" ? (
                      <button onClick={() => handleDisable(user.id)}>
                        Disable
                      </button>
                    ) : (
                      <button onClick={() => handleEnable(user.id)}>
                        Enable
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {resetPass && (
          <div className="reset-password-form">
            <input
              type="password"
              placeholder="New password"
              value={resetPass.password}
              onChange={(e) =>
                setResetPass({ ...resetPass, password: e.target.value })
              }
            />
            <button onClick={() => handleResetPassword(resetPass.userId)}>
              Confirm Reset
            </button>
          </div>
        )}
      </section>
    </div>
  );
}
