import type { ReactNode } from "react";

interface FieldRowProps {
  label: ReactNode;
  children: ReactNode;
}

export function FieldRow({ label, children }: FieldRowProps) {
  return (
    <label className="grid grid-cols-[minmax(96px,0.8fr)_minmax(0,1.4fr)] items-center gap-4 min-h-14 p-2.5 border-b border-border last:border-b-0 max-sm:grid-cols-[minmax(82px,0.7fr)_minmax(0,1.3fr)] max-sm:gap-3">
      <span>{label}</span>
      {children}
    </label>
  );
}
