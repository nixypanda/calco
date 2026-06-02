import { Alert } from "@mantine/core";

export function ErrorBanner({ message }: { message: string }) {
  return (
    <Alert role="alert" color="red" variant="light">
      {message}
    </Alert>
  );
}
