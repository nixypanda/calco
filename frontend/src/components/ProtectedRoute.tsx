import { Navigate } from "react-router-dom";
import { Center, Text } from "@mantine/core";
import { useAuth } from "../hooks/AuthContext";

export function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { isAuthenticated, loading } = useAuth();
  if (loading)
    return (
      <Center mih="100dvh" p="md">
        <Text fw={600} c="dimmed">
          Loading...
        </Text>
      </Center>
    );
  if (!isAuthenticated) return <Navigate to="/login" replace />;
  return <>{children}</>;
}
