import {
  createContext,
  useContext,
  useState,
  useCallback,
  useEffect,
  type ReactNode,
} from "react";
import {
  login as apiLogin,
  logout as apiLogout,
  getSession as apiGetSession,
  createAdmin as apiCreateAdmin,
  checkBootstrapStatus,
} from "../api/auth";
import type {
  IdentityResponse,
  ProfileResponse,
} from "../api/auth";
import { UNAUTHORIZED_EVENT } from "../api/client";

export interface AuthState {
  identity: IdentityResponse | null;
  profile: ProfileResponse | null;
  loading: boolean;
  isAuthenticated: boolean;
  isAdmin: boolean;
  adminExists: boolean;
}

export interface AuthContextValue extends AuthState {
  login: (username: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
  createAdmin: (username: string, password: string) => Promise<void>;
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [identity, setIdentity] = useState<IdentityResponse | null>(null);
  const [profile, setProfile] = useState<ProfileResponse | null>(null);
  const [adminExists, setAdminExists] = useState(true);
  const [loading, setLoading] = useState(true);

  const bootstrap = useCallback(async () => {
    const [sessionRes, statusRes] = await Promise.allSettled([
      apiGetSession(),
      checkBootstrapStatus(),
    ]);
    if (sessionRes.status === "fulfilled") {
      setIdentity(sessionRes.value.identity);
      setProfile(sessionRes.value.profile);
    } else {
      setIdentity(null);
      setProfile(null);
    }
    setAdminExists(
      statusRes.status === "fulfilled" ? statusRes.value.admin_exists : true,
    );
    setLoading(false);
  }, []);

  useEffect(() => {
    bootstrap();
  }, [bootstrap]);

  useEffect(() => {
    const handler = () => {
      setIdentity(null);
      setProfile(null);
      if (window.location.pathname !== "/login") {
        window.location.assign("/login");
      }
    };
    window.addEventListener(UNAUTHORIZED_EVENT, handler);
    return () => window.removeEventListener(UNAUTHORIZED_EVENT, handler);
  }, []);

  const login = useCallback(async (username: string, password: string) => {
    const resp = await apiLogin(username, password);
    setIdentity(resp.identity);
    setProfile(resp.profile);
  }, []);

  const logout = useCallback(async () => {
    try {
      await apiLogout();
    } finally {
      setIdentity(null);
      setProfile(null);
    }
  }, []);

  const createAdmin = useCallback(
    async (username: string, password: string) => {
      const resp = await apiCreateAdmin(username, password);
      setIdentity(resp.identity);
      setProfile(resp.profile);
      setAdminExists(true);
    },
    [],
  );

  const value: AuthContextValue = {
    identity,
    profile,
    loading,
    isAuthenticated: identity !== null,
    isAdmin: identity?.role === "admin",
    adminExists,
    login,
    logout,
    createAdmin,
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
