import { useState, type SubmitEvent } from "react";
import { Navigate, useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/AuthContext";
import {
  Paper,
  Button,
  TextInput,
  Stack,
  Center,
  Title,
  Text,
} from "@mantine/core";
import { ErrorBanner } from "@/components/ErrorBanner";

export function BootstrapAdminSetup() {
  const navigate = useNavigate();
  const { createAdmin, isAdmin } = useAuth();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);

  if (isAdmin) {
    return <Navigate to="/admin" replace />;
  }

  const handleSubmit = async (e: SubmitEvent<HTMLFormElement>) => {
    e.preventDefault();
    setError("");
    if (!username.trim()) {
      setError("Username is required");
      return;
    }
    if (password.length < 8) {
      setError("Password must be at least 8 characters");
      return;
    }
    setSubmitting(true);
    try {
      await createAdmin(username, password);
      navigate("/admin", { replace: true });
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to create admin");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Center mih="100dvh" p="md">
      <Paper w="100%" maw={400} p="lg">
        <Title order={1}>CalCo</Title>
        <Title order={2} fw={600} c="dimmed">
          First-Time Setup
        </Title>
        <Text size="sm" c="dimmed" mb="md">
          Create the admin account to get started.
        </Text>
        <form onSubmit={handleSubmit}>
          <Stack gap="md" mt="md">
            <TextInput
              id="username"
              label="Username"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              autoFocus
              disabled={submitting}
            />
            <TextInput
              id="password"
              label="Password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              disabled={submitting}
            />
            {error && <ErrorBanner message={error} />}
            <Button type="submit" disabled={submitting}>
              {submitting ? "Creating..." : "Create Admin"}
            </Button>
          </Stack>
        </form>
      </Paper>
    </Center>
  );
}
