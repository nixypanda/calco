import type { ReactNode } from "react";
import { Group } from "@mantine/core";

interface FieldRowProps {
  label: ReactNode;
  children: ReactNode;
}

export function FieldRow({ label, children }: FieldRowProps) {
  return (
    <Group
      component="label"
      justify="space-between"
      align="center"
      gap="md"
      p="xs"
      style={{ borderBottom: "1px solid var(--mantine-color-default-border)" }}
    >
      <span>{label}</span>
      {children}
    </Group>
  );
}
