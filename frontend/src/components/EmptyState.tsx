import { Center } from "@mantine/core";
import type { ReactNode } from "react";

export function EmptyState({ children }: { children: ReactNode }) {
  return <Center p="lg">{children}</Center>;
}
