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
  const arcs = segments.map((seg, i) => {
    const length = denom > 0 ? Math.min(seg.value / denom, 1) * circumference : 0;
    const arc = (
      <circle
        key={i}
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
    <div className="relative inline-flex items-center justify-center" style={{ width: size, height: size }}>
      <svg width={size} height={size}>
        <circle
          cx={size / 2}
          cy={size / 2}
          r={radius}
          fill="none"
          stroke="hsl(var(--border))"
          strokeWidth={strokeWidth}
        />
        {arcs}
      </svg>
      {children && (
        <div className="absolute inset-0 flex flex-col items-center justify-center pointer-events-none">
          {children}
        </div>
      )}
    </div>
  );
}
