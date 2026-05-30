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
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

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
          <Button variant="outline" size="sm" onClick={logout}>Logout</Button>
        </div>
      </header>

      {error && <p className="mb-4 p-3 bg-red-50 border border-red-200 rounded-xl text-red-500 font-semibold text-sm">{error}</p>}

      <section>
        <div className="flex items-center justify-between gap-3 mb-3.5">
          <h2>Users</h2>
          <Button variant="outline" size="sm" onClick={() => setShowCreate(!showCreate)}>
            {showCreate ? "Cancel" : "Create User"}
          </Button>
        </div>

        {showCreate && (
          <form className="flex gap-2.5 mb-4" onSubmit={handleCreate}>
            <Input
              placeholder="Username"
              value={newUser.username}
              onChange={(e) =>
                setNewUser({ ...newUser, username: e.target.value })
              }
              className="flex-1"
            />
            <Input
              placeholder="Display Name"
              value={newUser.display_name}
              onChange={(e) =>
                setNewUser({ ...newUser, display_name: e.target.value })
              }
              className="flex-1"
            />
            <Input
              type="password"
              placeholder="Initial Password"
              value={newUser.initial_password}
              onChange={(e) =>
                setNewUser({ ...newUser, initial_password: e.target.value })
              }
              className="flex-1"
            />
            <Button type="submit">Save</Button>
          </form>
        )}

        {loading ? (
          <p>Loading users...</p>
        ) : users.length === 0 ? (
          <p>No users yet.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Username</TableHead>
                <TableHead>Display Name</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {users.map((user) => (
                <TableRow key={user.id}>
                  <TableCell>{user.username}</TableCell>
                  <TableCell>{user.display_name}</TableCell>
                  <TableCell>{user.status}</TableCell>
                  <TableCell className="flex gap-2.5 flex-wrap">
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() =>
                        setResetPass(
                          resetPass?.userId === user.id
                            ? null
                            : { userId: user.id, password: "" },
                        )
                      }
                    >
                      Reset Password
                    </Button>
                    {user.status === "active" ? (
                      <Button variant="outline" size="sm" onClick={() => handleDisable(user.id)}>
                        Disable
                      </Button>
                    ) : (
                      <Button variant="outline" size="sm" onClick={() => handleEnable(user.id)}>
                        Enable
                      </Button>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}

        {resetPass && (
          <div className="flex gap-2.5 mb-4">
            <Input
              type="password"
              placeholder="New password"
              value={resetPass.password}
              onChange={(e) =>
                setResetPass({ ...resetPass, password: e.target.value })
              }
              className="flex-1"
            />
            <Button onClick={() => handleResetPassword(resetPass.userId)}>
              Confirm Reset
            </Button>
          </div>
        )}
      </section>
    </div>
  );
}
