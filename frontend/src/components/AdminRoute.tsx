import { Center, Text } from "@mantine/core";
import { Navigate } from "react-router-dom";
import { useAuth } from "../hooks/AuthContext";

export function AdminRoute({ children }: { children: React.ReactNode }) {
  const { isAuthenticated, isAdmin, loading } = useAuth();
  if (loading)
    return (
      <Center mih="100dvh" p="md">
        <Text fw={600} c="dimmed">
          Loading...
        </Text>
      </Center>
    );
  if (!isAuthenticated) return <Navigate to="/login" replace />;
  if (!isAdmin) return <Navigate to="/" replace />;
  return <>{children}</>;
}
