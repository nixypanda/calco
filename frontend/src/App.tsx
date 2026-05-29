import { useState, useEffect } from "react";
import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { AuthProvider, useAuth } from "./hooks/AuthContext";
import { ProtectedRoute } from "./components/ProtectedRoute";
import { AdminRoute } from "./components/AdminRoute";
import { BootstrapAdminSetup } from "./pages/BootstrapAdminSetup";
import { LoginPage } from "./pages/LoginPage";
import { AdminDashboard } from "./pages/AdminDashboard";
import { UserHome } from "./pages/UserHome";
import { checkBootstrapStatus } from "./api/auth";

function RootRedirect() {
  const { loading, isAuthenticated, isAdmin } = useAuth();
  const [status, setStatus] = useState<{
    loading: boolean;
    adminExists: boolean;
  }>({ loading: true, adminExists: true });

  useEffect(() => {
    checkBootstrapStatus()
      .then((r) => setStatus({ loading: false, adminExists: r.admin_exists }))
      .catch(() => setStatus({ loading: false, adminExists: true }));
  }, []);

  if (loading || status.loading) {
    return <div className="page-loading">Loading...</div>;
  }

  if (!status.adminExists) return <Navigate to="/setup" replace />;
  if (!isAuthenticated) return <Navigate to="/login" replace />;
  if (isAdmin) return <Navigate to="/admin" replace />;
  return <Navigate to="/home" replace />;
}

function BootstrapGate({ children }: { children: React.ReactNode }) {
  const { loading, isAuthenticated } = useAuth();
  const [adminExists, setAdminExists] = useState<boolean | null>(null);

  useEffect(() => {
    checkBootstrapStatus()
      .then((r) => setAdminExists(r.admin_exists))
      .catch(() => setAdminExists(true));
  }, []);

  if (loading || adminExists === null) {
    return <div className="page-loading">Loading...</div>;
  }

  if (adminExists && !isAuthenticated) return <Navigate to="/login" replace />;
  if (isAuthenticated) return <Navigate to="/" replace />;
  return <>{children}</>;
}

function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <Routes>
          <Route
            path="/setup"
            element={
              <BootstrapGate>
                <BootstrapAdminSetup />
              </BootstrapGate>
            }
          />
          <Route path="/login" element={<LoginPage />} />
          <Route
            path="/admin"
            element={
              <AdminRoute>
                <AdminDashboard />
              </AdminRoute>
            }
          />
          <Route
            path="/home"
            element={
              <ProtectedRoute>
                <UserHome />
              </ProtectedRoute>
            }
          />
          <Route path="/" element={<RootRedirect />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </AuthProvider>
    </BrowserRouter>
  );
}

export default App;
