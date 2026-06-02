import { Button, Center, Paper, Stack, TextInput, Title } from "@mantine/core";
import { type SubmitEvent, useState } from "react";
import { Navigate, useNavigate } from "react-router-dom";
import { ErrorBanner } from "@/components/ErrorBanner";
import { useAuth } from "../hooks/AuthContext";

export function LoginPage() {
  const navigate = useNavigate();
  const { login, isAuthenticated, isAdmin } = useAuth();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);

  if (isAuthenticated) {
    return <Navigate to={isAdmin ? "/admin" : "/"} replace />;
  }

  const handleSubmit = async (e: SubmitEvent<HTMLFormElement>) => {
    e.preventDefault();
    setError("");
    const trimmedUsername = username.trim();
    if (!trimmedUsername || !password) {
      setError("Username and password are required");
      return;
    }
    setSubmitting(true);
    try {
      await login(trimmedUsername, password);
      navigate("/", { replace: true });
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Login failed");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Center mih="100dvh" p="md">
      <Paper w="100%" maw={400} p="lg">
        <Title order={1}>CalCo</Title>
        <Title order={2} fw={600} c="dimmed">
          Log In
        </Title>
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
              {submitting ? "Logging in..." : "Log In"}
            </Button>
          </Stack>
        </form>
      </Paper>
    </Center>
  );
}
