import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { ProtectedRoute } from "../components/ProtectedRoute";
import { AdminRoute } from "../components/AdminRoute";

const mockGetSession = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

function renderGuards(initialEntries: string[]) {
  return render(
    <MemoryRouter initialEntries={initialEntries}>
      <AuthProvider>
        <Routes>
          <Route
            path="/protected"
            element={
              <ProtectedRoute>
                <div>Protected Content</div>
              </ProtectedRoute>
            }
          />
          <Route
            path="/admin-only"
            element={
              <AdminRoute>
                <div>Admin Content</div>
              </AdminRoute>
            }
          />
          <Route path="/login" element={<div>Login Page</div>} />
          <Route path="/" element={<div>Home Page</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe("ProtectedRoute", () => {
  it("redirects to login when unauthenticated", async () => {
    mockGetSession.mockRejectedValue(new Error("no session"));

    renderGuards(["/protected"]);

    await waitFor(() => {
      expect(screen.getByText("Login Page")).toBeInTheDocument();
    });
  });

  it("renders children when authenticated", async () => {
    mockGetSession.mockResolvedValue({
      identity: { id: "1", username: "alice", role: "user" },
      profile: { id: "p1", display_name: "Alice" },
    });

    renderGuards(["/protected"]);

    await waitFor(() => {
      expect(screen.getByText("Protected Content")).toBeInTheDocument();
    });
  });
});

describe("AdminRoute", () => {
  it("redirects to login when unauthenticated", async () => {
    mockGetSession.mockRejectedValue(new Error("no session"));

    renderGuards(["/admin-only"]);

    await waitFor(() => {
      expect(screen.getByText("Login Page")).toBeInTheDocument();
    });
  });

  it("redirects to home for non-admin users", async () => {
    mockGetSession.mockResolvedValue({
      identity: { id: "1", username: "alice", role: "user" },
      profile: { id: "p1", display_name: "Alice" },
    });

    renderGuards(["/admin-only"]);

    await waitFor(() => {
      expect(screen.getByText("Home Page")).toBeInTheDocument();
    });
  });

  it("renders admin content for admins", async () => {
    mockGetSession.mockResolvedValue({
      identity: { id: "1", username: "admin", role: "admin" },
      profile: null,
    });

    renderGuards(["/admin-only"]);

    await waitFor(() => {
      expect(screen.getByText("Admin Content")).toBeInTheDocument();
    });
  });
});
