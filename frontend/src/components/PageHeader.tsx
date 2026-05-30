import type { ReactNode } from "react";
import { Button } from "@/components/ui/button";

interface PageHeaderProps {
  title: ReactNode;
  onBack?: () => void;
  backLabel?: string;
  children?: ReactNode;
}

export function PageHeader({ title, onBack, backLabel = "Back", children }: PageHeaderProps) {
  return (
    <header className="flex items-center justify-between gap-4 mb-4">
      <div className="flex items-center gap-2.5 min-w-0">
        {onBack && (
          <Button
            variant="ghost"
            size="icon"
            onClick={onBack}
            aria-label={backLabel}
            className="text-muted-foreground"
          >
            <span aria-hidden="true" className="text-xl font-extrabold leading-none">←</span>
          </Button>
        )}
        <h1 className="truncate">{title}</h1>
      </div>
      {children && <div className="flex flex-wrap gap-2.5">{children}</div>}
    </header>
  );
}
