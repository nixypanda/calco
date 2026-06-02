import { Box, Stack } from "@mantine/core";
import type { ReactNode } from "react";

interface Segment {
  value: number;
  color: string;
}

interface MacroRingProps {
  segments: Segment[];
  total?: number;
  size?: number;
  strokeWidth?: number;
  children?: ReactNode;
}

export function MacroRing({
  segments,
  total,
  size = 80,
  strokeWidth = 6,
  children,
}: MacroRingProps) {
  const radius = (size - strokeWidth) / 2;
  const circumference = 2 * Math.PI * radius;
  const sum = segments.reduce((s, seg) => s + seg.value, 0);
  const denom = total ?? sum;

  let offset = 0;
  const arcs = segments.map((seg) => {
    const length =
      denom > 0 ? Math.min(seg.value / denom, 1) * circumference : 0;
    const arc = (
      <circle
        key={seg.color}
        cx={size / 2}
        cy={size / 2}
        r={radius}
        fill="none"
        stroke={seg.color}
        strokeWidth={strokeWidth}
        strokeDasharray={`${length} ${circumference - length}`}
        strokeDashoffset={-offset}
        transform={`rotate(-90 ${size / 2} ${size / 2})`}
        strokeLinecap={segments.length === 1 ? "round" : "butt"}
      />
    );
    offset += length;
    return arc;
  });

  return (
    <Box
      pos="relative"
      display="inline-flex"
      style={{ width: size, height: size }}
    >
      <svg width={size} height={size} role="img" aria-label="Macro ring">
        <circle
          cx={size / 2}
          cy={size / 2}
          r={radius}
          fill="none"
          stroke="var(--mantine-color-gray-2)"
          strokeWidth={strokeWidth}
        />
        {arcs}
      </svg>
      {children && (
        <Stack
          gap={0}
          align="center"
          justify="center"
          pos="absolute"
          top={0}
          left={0}
          right={0}
          bottom={0}
          style={{ pointerEvents: "none" }}
        >
          {children}
        </Stack>
      )}
    </Box>
  );
}
