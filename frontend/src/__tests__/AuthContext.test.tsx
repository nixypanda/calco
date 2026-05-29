import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AuthProvider, useAuth } from "../hooks/AuthContext";

const mockGetSession = vi.fn();
const mockLogin = vi.fn();
const mockLogout = vi.fn();
const mockCreateAdmin = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: (...args: unknown[]) => mockLogin(...args),
  logout: (...args: unknown[]) => mockLogout(...args),
  createAdmin: (...args: unknown[]) => mockCreateAdmin(...args),
}));

function TestConsumer() {
  const auth = useAuth();
  return (
    <div>
      <span data-testid="loading">{String(auth.loading)}</span>
      <span data-testid="authenticated">{String(auth.isAuthenticated)}</span>
      <span data-testid="is-admin">{String(auth.isAdmin)}</span>
      <span data-testid="identity">{JSON.stringify(auth.identity)}</span>
      <span data-testid="profile">{JSON.stringify(auth.profile)}</span>
      <button data-testid="login-btn" onClick={() => auth.login("u", "p")}>
        login
      </button>
      <button data-testid="logout-btn" onClick={() => auth.logout()}>
        logout
      </button>
      <button
        data-testid="create-admin-btn"
        onClick={() => auth.createAdmin("admin", "pass1234")}
      >
        create admin
      </button>
    </div>
  );
}

function renderWithProvider() {
  return render(
    <AuthProvider>
      <TestConsumer />
    </AuthProvider>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe("AuthContext", () => {
  it("shows loading initially then resolves", async () => {
    mockGetSession.mockResolvedValue({
      identity: { id: "1", username: "test", role: "user" },
      profile: { id: "p1", display_name: "Test" },
    });

    renderWithProvider();

    expect(screen.getByTestId("loading")).toHaveTextContent("true");

    await waitFor(() => {
      expect(screen.getByTestId("loading")).toHaveTextContent("false");
    });
    expect(screen.getByTestId("authenticated")).toHaveTextContent("true");
    expect(screen.getByTestId("is-admin")).toHaveTextContent("false");
  });

  it("detects admin role", async () => {
    mockGetSession.mockResolvedValue({
      identity: { id: "1", username: "admin", role: "admin" },
      profile: null,
    });

    renderWithProvider();

    await waitFor(() => {
      expect(screen.getByTestId("is-admin")).toHaveTextContent("true");
    });
  });

  it("sets unauthenticated when session fails", async () => {
    mockGetSession.mockRejectedValue(new Error("no session"));

    renderWithProvider();

    await waitFor(() => {
      expect(screen.getByTestId("authenticated")).toHaveTextContent("false");
    });
  });

  it("login sets identity", async () => {
    mockGetSession.mockRejectedValue(new Error("no session"));
    mockLogin.mockResolvedValue({
      identity: { id: "2", username: "alice", role: "user" },
      profile: { id: "p2", display_name: "Alice" },
    });

    renderWithProvider();

    await waitFor(() => {
      expect(screen.getByTestId("loading")).toHaveTextContent("false");
    });

    await userEvent.click(screen.getByTestId("login-btn"));

    await waitFor(() => {
      expect(screen.getByTestId("authenticated")).toHaveTextContent("true");
    });
  });

  it("logout clears identity", async () => {
    mockGetSession.mockResolvedValue({
      identity: { id: "1", username: "test", role: "user" },
      profile: null,
    });

    renderWithProvider();

    await waitFor(() => {
      expect(screen.getByTestId("authenticated")).toHaveTextContent("true");
    });

    await userEvent.click(screen.getByTestId("logout-btn"));

    await waitFor(() => {
      expect(screen.getByTestId("authenticated")).toHaveTextContent("false");
    });
  });

  it("createAdmin sets admin identity", async () => {
    mockGetSession.mockRejectedValue(new Error("no session"));
    mockCreateAdmin.mockResolvedValue({
      identity: { id: "3", username: "admin", role: "admin" },
      profile: null,
    });

    renderWithProvider();

    await waitFor(() => {
      expect(screen.getByTestId("loading")).toHaveTextContent("false");
    });

    await userEvent.click(screen.getByTestId("create-admin-btn"));

    await waitFor(() => {
      expect(screen.getByTestId("is-admin")).toHaveTextContent("true");
    });
  });
});
