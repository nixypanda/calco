import { Center, Text } from "@mantine/core";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { AdminRoute } from "./components/AdminRoute";
import { ProtectedRoute } from "./components/ProtectedRoute";
import { AuthProvider, useAuth } from "./hooks/AuthContext";
import { AdminDashboard } from "./pages/AdminDashboard";
import { BootstrapAdminSetup } from "./pages/BootstrapAdminSetup";
import { CustomFoodCreate } from "./pages/CustomFoodCreate";
import { CustomFoodEdit } from "./pages/CustomFoodEdit";
import { Diary } from "./pages/Diary";
import { FoodDetail } from "./pages/FoodDetail";
import { FoodLogDetail } from "./pages/FoodLogDetail";
import { FoodSearch } from "./pages/FoodSearch";
import { LoginPage } from "./pages/LoginPage";
import { MealDetail } from "./pages/MealDetail";
import { MealForm } from "./pages/MealForm";
import { Meals } from "./pages/Meals";

function LoadingScreen() {
  return (
    <Center mih="100dvh" p="md">
      <Text fw={600} c="dimmed">
        Loading...
      </Text>
    </Center>
  );
}

function RootRedirect() {
  const { loading, isAuthenticated, isAdmin, adminExists } = useAuth();

  if (loading) return <LoadingScreen />;
  if (!adminExists) return <Navigate to="/setup" replace />;
  if (!isAuthenticated) return <Navigate to="/login" replace />;
  if (isAdmin) return <Navigate to="/admin" replace />;
  return <Navigate to="/home" replace />;
}

function BootstrapGate({ children }: { children: React.ReactNode }) {
  const { loading, isAuthenticated, adminExists } = useAuth();

  if (loading) return <LoadingScreen />;
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
                <Diary />
              </ProtectedRoute>
            }
          />
          <Route
            path="/logs/:id"
            element={
              <ProtectedRoute>
                <FoodLogDetail />
              </ProtectedRoute>
            }
          />
          <Route
            path="/search"
            element={
              <ProtectedRoute>
                <FoodSearch />
              </ProtectedRoute>
            }
          />
          <Route
            path="/foods/:id"
            element={
              <ProtectedRoute>
                <FoodDetail />
              </ProtectedRoute>
            }
          />
          <Route
            path="/foods/custom/new"
            element={
              <ProtectedRoute>
                <CustomFoodCreate />
              </ProtectedRoute>
            }
          />
          <Route
            path="/foods/custom/:id/edit"
            element={
              <ProtectedRoute>
                <CustomFoodEdit />
              </ProtectedRoute>
            }
          />
          <Route
            path="/meals"
            element={
              <ProtectedRoute>
                <Meals />
              </ProtectedRoute>
            }
          />
          <Route
            path="/meals/new"
            element={
              <ProtectedRoute>
                <MealForm />
              </ProtectedRoute>
            }
          />
          <Route
            path="/meals/:id"
            element={
              <ProtectedRoute>
                <MealDetail />
              </ProtectedRoute>
            }
          />
          <Route
            path="/meals/:id/edit"
            element={
              <ProtectedRoute>
                <MealForm />
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
