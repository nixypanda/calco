import { apiRequest } from "./client";

export interface BootstrapStatus {
  admin_exists: boolean;
}

export interface IdentityResponse {
  id: string;
  username: string;
  role: string;
}

export interface ProfileResponse {
  id: string;
  display_name: string;
}

export interface LoginSessionResponse {
  identity: IdentityResponse;
  profile: ProfileResponse | null;
}

export async function checkBootstrapStatus(): Promise<BootstrapStatus> {
  return apiRequest<BootstrapStatus>("/api/auth/bootstrap/status");
}

export async function createAdmin(
  username: string,
  password: string,
): Promise<LoginSessionResponse> {
  return apiRequest<LoginSessionResponse>("/api/auth/bootstrap/admin", {
    method: "POST",
    body: JSON.stringify({ username, password }),
  });
}

export async function login(
  username: string,
  password: string,
): Promise<LoginSessionResponse> {
  return apiRequest<LoginSessionResponse>("/api/auth/login", {
    method: "POST",
    body: JSON.stringify({ username, password }),
  });
}

export async function getSession(): Promise<LoginSessionResponse> {
  return apiRequest<LoginSessionResponse>("/api/auth/session");
}

export async function logout(): Promise<void> {
  await apiRequest<void>("/api/auth/logout", { method: "POST" });
}
