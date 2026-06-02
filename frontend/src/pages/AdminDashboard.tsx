import { useState, useEffect, useCallback, type SubmitEvent } from "react";
import { useAuth } from "../hooks/AuthContext";
import {
  listUsers,
  createUser,
  resetPassword,
  disableUser,
  enableUser,
} from "../api/admin";
import type { UserItem } from "../api/admin";
import {
  Button,
  TextInput,
  Table,
  Container,
  Group,
  Stack,
  Title,
  Text,
} from "@mantine/core";
import { ErrorBanner } from "@/components/ErrorBanner";

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

  const fetchUsers = useCallback(async () => {
    try {
      const resp = await listUsers();
      setUsers(resp.users);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to load users");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchUsers();
  }, [fetchUsers]);

  const handleCreate = async (e: SubmitEvent<HTMLFormElement>) => {
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
      setError(err instanceof Error ? err.message : "Failed to reset password");
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
    <Container p="md">
      <Group component="header" justify="space-between" mb="md">
        <Title order={1}>Admin Dashboard</Title>
        <Group gap="sm">
          <Text size="sm" c="dimmed">
            Logged in as <strong>{identity?.username}</strong>
          </Text>
          <Button variant="outline" size="sm" onClick={logout}>
            Logout
          </Button>
        </Group>
      </Group>

      {error && <ErrorBanner message={error} />}

      <Stack gap="md">
        <Group justify="space-between">
          <Title order={2}>Users</Title>
          <Button
            variant="outline"
            size="sm"
            onClick={() => setShowCreate(!showCreate)}
          >
            {showCreate ? "Cancel" : "Create User"}
          </Button>
        </Group>

        {showCreate && (
          <form onSubmit={handleCreate}>
            <Group gap="xs">
              <TextInput
                placeholder="Username"
                value={newUser.username}
                onChange={(e) =>
                  setNewUser({ ...newUser, username: e.target.value })
                }
                style={{ flex: 1 }}
              />
              <TextInput
                placeholder="Display Name"
                value={newUser.display_name}
                onChange={(e) =>
                  setNewUser({ ...newUser, display_name: e.target.value })
                }
                style={{ flex: 1 }}
              />
              <TextInput
                type="password"
                placeholder="Initial Password"
                value={newUser.initial_password}
                onChange={(e) =>
                  setNewUser({ ...newUser, initial_password: e.target.value })
                }
                style={{ flex: 1 }}
              />
              <Button type="submit">Save</Button>
            </Group>
          </form>
        )}

        {loading ? (
          <Text>Loading users...</Text>
        ) : users.length === 0 ? (
          <Text>No users yet.</Text>
        ) : (
          <Table>
            <Table.Thead>
              <Table.Tr>
                <Table.Th>Username</Table.Th>
                <Table.Th>Display Name</Table.Th>
                <Table.Th>Status</Table.Th>
                <Table.Th>Actions</Table.Th>
              </Table.Tr>
            </Table.Thead>
            <Table.Tbody>
              {users.map((user) => (
                <Table.Tr key={user.id}>
                  <Table.Td>{user.username}</Table.Td>
                  <Table.Td>{user.display_name}</Table.Td>
                  <Table.Td>{user.status}</Table.Td>
                  <Table.Td>
                    <Group gap="xs" wrap="wrap">
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
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => handleDisable(user.id)}
                        >
                          Disable
                        </Button>
                      ) : (
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => handleEnable(user.id)}
                        >
                          Enable
                        </Button>
                      )}
                    </Group>
                  </Table.Td>
                </Table.Tr>
              ))}
            </Table.Tbody>
          </Table>
        )}

        {resetPass && (
          <Group gap="xs" mt="md">
            <TextInput
              type="password"
              placeholder="New password"
              value={resetPass.password}
              onChange={(e) =>
                setResetPass({ ...resetPass, password: e.target.value })
              }
              style={{ flex: 1 }}
            />
            <Button onClick={() => handleResetPassword(resetPass.userId)}>
              Confirm Reset
            </Button>
          </Group>
        )}
      </Stack>
    </Container>
  );
}
