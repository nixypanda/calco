import "@testing-library/jest-dom/vitest";
import { MantineProvider } from "@mantine/core";
import React from "react";
import { vi } from "vitest";

// Radix Select / DropdownMenu rely on PointerEvent APIs that jsdom doesn't implement.
if (typeof Element !== "undefined") {
  if (!Element.prototype.hasPointerCapture) {
    Element.prototype.hasPointerCapture = vi.fn(() => false);
  }
  if (!Element.prototype.releasePointerCapture) {
    Element.prototype.releasePointerCapture = vi.fn();
  }
  if (!Element.prototype.scrollIntoView) {
    Element.prototype.scrollIntoView = vi.fn();
  }
}

// Mantine reads window.matchMedia for color scheme detection.
if (typeof window !== "undefined" && !window.matchMedia) {
  window.matchMedia = vi.fn().mockImplementation((query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  }));
}

vi.mock("@testing-library/react", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("@testing-library/react")>();
  const Wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(MantineProvider, null, children);
  return {
    ...actual,
    render: (
      ui: React.ReactElement,
      options: Parameters<typeof actual.render>[1] = {},
    ) => actual.render(ui, { wrapper: Wrapper, ...options }),
  };
});
