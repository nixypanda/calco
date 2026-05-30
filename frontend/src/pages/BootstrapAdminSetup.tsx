import { useState, type SubmitEvent } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/AuthContext";
import { Card, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ErrorBanner } from "@/components/ErrorBanner";

export function BootstrapAdminSetup() {
  const navigate = useNavigate();
  const { createAdmin, isAdmin } = useAuth();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);

  if (isAdmin) {
    navigate("/admin", { replace: true });
    return null;
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
    <div className="min-h-dvh flex items-center justify-center p-4">
      <Card className="w-full max-w-sm p-6">
        <CardTitle className="text-2xl font-extrabold">CalCo</CardTitle>
        <h1 className="text-base font-semibold text-muted-foreground">First-Time Setup</h1>
        <p className="text-sm text-muted-foreground mb-4">Create the admin account to get started.</p>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4 mt-4">
          <div className="flex flex-col gap-2">
            <Label htmlFor="username">Username</Label>
            <Input
              id="username"
              type="text"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              autoFocus
              disabled={submitting}
            />
          </div>
          <div className="flex flex-col gap-2">
            <Label htmlFor="password">Password</Label>
            <Input
              id="password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              disabled={submitting}
            />
          </div>
          {error && <ErrorBanner message={error} />}
          <Button type="submit" disabled={submitting}>
            {submitting ? "Creating..." : "Create Admin"}
          </Button>
        </form>
      </Card>
    </div>
  );
}
