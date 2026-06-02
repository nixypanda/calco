import type { LoginSessionResponse } from "./auth";
import { apiRequest } from "./client";

export interface UserItem {
  id: string;
  username: string;
  display_name: string;
  status: string;
  created_at: string;
}

export interface ListUsersResponse {
  users: UserItem[];
}

export interface CreateUserRequest {
  username: string;
  display_name: string;
  initial_password: string;
}

export async function listUsers(): Promise<ListUsersResponse> {
  return apiRequest<ListUsersResponse>("/api/admin/users");
}

export async function createUser(
  data: CreateUserRequest,
): Promise<LoginSessionResponse> {
  return apiRequest<LoginSessionResponse>("/api/admin/users", {
    method: "POST",
    body: JSON.stringify(data),
  });
}

export async function resetPassword(
  userId: string,
  newPassword: string,
): Promise<void> {
  await apiRequest<void>(`/api/admin/users/${userId}/reset-password`, {
    method: "POST",
    body: JSON.stringify({ new_password: newPassword }),
  });
}

export async function disableUser(userId: string): Promise<void> {
  await apiRequest<void>(`/api/admin/users/${userId}/disable`, {
    method: "POST",
  });
}

export async function enableUser(userId: string): Promise<void> {
  await apiRequest<void>(`/api/admin/users/${userId}/enable`, {
    method: "POST",
  });
}
