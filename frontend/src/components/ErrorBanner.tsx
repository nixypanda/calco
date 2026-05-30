export function ErrorBanner({ message }: { message: string }) {
  return (
    <p
      role="alert"
      className="mb-4 p-3 bg-destructive/10 border border-destructive/30 rounded-xl text-destructive font-semibold text-sm"
    >
      {message}
    </p>
  );
}
