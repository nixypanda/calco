import type { ReactNode } from "react";
import { Center } from "@mantine/core";

export function EmptyState({ children }: { children: ReactNode }) {
  return <Center p="lg">{children}</Center>;
}
