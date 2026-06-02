import type { ReactNode } from "react";
import { ActionIcon, Group, Title } from "@mantine/core";

interface PageHeaderProps {
  title: ReactNode;
  onBack?: () => void;
  backLabel?: string;
  children?: ReactNode;
}

export function PageHeader({ title, onBack, backLabel = "Back", children }: PageHeaderProps) {
  return (
    <Group component="header" justify="space-between" gap="md" mb="md">
      <Group gap="xs" miw={0}>
        {onBack && (
          <ActionIcon
            variant="subtle"
            color="gray"
            onClick={onBack}
            aria-label={backLabel}
          >
            <span aria-hidden="true">←</span>
          </ActionIcon>
        )}
        <Title order={1} style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
          {title}
        </Title>
      </Group>
      {children && <Group gap="xs">{children}</Group>}
    </Group>
  );
}
