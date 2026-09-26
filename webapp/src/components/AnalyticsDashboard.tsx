"use client";

import { useState, type ReactNode } from "react";
import type { DashboardAnalytics, HourPoint, TenurePoint, WeekPoint } from "@/lib/analytics";
import { format } from "@/lib/date";

type Props = { analytics: DashboardAnalytics; loading: boolean; weeks: number; onWeeksChange: (weeks: number) => void };

export function AnalyticsDashboard({ analytics, loading, weeks, onWeeksChange }: Props) {
  return (
    <section className="analytics-column" aria-label="Patient analytics">
      <WeeklyChart points={analytics.weeks} loading={loading} weeks={weeks} onWeeksChange={onWeeksChange} />
      <SignalCarousel analytics={analytics} loading={loading} />
    </section>
  );
}

type Panel = { key: string; title: string; icon: ReactNode; legend?: ReactNode; body: ReactNode };

const ICON = { width: 14, height: 14, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 2, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, "aria-hidden": true };
const ClockIcon = () => <svg {...ICON}><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></svg>;
const PulseIcon = () => <svg {...ICON}><path d="M3 12h4l2-6 4 12 2-6h6" /></svg>;
const PeopleIcon = () => <svg {...ICON}><circle cx="9" cy="8" r="3.5" /><path d="M2.5 20a6.5 6.5 0 0 1 13 0" /><circle cx="17" cy="9" r="2.5" /><path d="M16 15.5a5 5 0 0 1 5.5 4.5" /></svg>;

function SignalCarousel({ analytics, loading }: { analytics: DashboardAnalytics; loading: boolean }) {
  const [index, setIndex] = useState(0);
  const panels: Panel[] = [
    {
      key: "hours",
      title: "Time of day",
      icon: <ClockIcon />,
      legend: <div className="chart-legend"><span><i className="violet-key" />Violet</span><span><i className="visit-key" />Visitors</span></div>,
      body: <HourlyChart points={analytics.hours} loading={loading} />,
    },
    { key: "health", title: "Recognition health", icon: <PulseIcon />, body: <HealthBar metric={analytics.health} /> },
    { key: "memory", title: "Memory by person", icon: <PeopleIcon />, body: <MemoryChart points={analytics.tenure} loading={loading} /> },
  ];
  const panel = panels[index];

  return (
    <article className="clinical-section signal-section">
      <div className="section-header">
        <h2>{panel.title}</h2>
        <div className="signal-controls">
          {panel.legend}
          <div className="signal-tabs" role="tablist" aria-label="Analytics views">
            {panels.map((item, position) => (
              <button
                key={item.key}
                type="button"
                role="tab"
                aria-selected={position === index}
                aria-label={item.title}
                title={item.title}
                className={position === index ? "active" : undefined}
                onClick={() => setIndex(position)}
              >
                {item.icon}
              </button>
            ))}
          </div>
        </div>
      </div>
      <div className="signal-panel" key={panel.key} role="tabpanel">{panel.body}</div>
    </article>
  );
}

function WeeklyChart({ points, loading, weeks, onWeeksChange }: { points: WeekPoint[]; loading: boolean; weeks: number; onWeeksChange: (weeks: number) => void }) {
  const width = 720;
  const height = 290;
  const margin = { top: 18, right: 48, bottom: 38, left: 42 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const countMax = Math.max(4, ...points.flatMap((point) => [point.violetUses, point.peopleSeen]));
  const countTop = Math.ceil(countMax / 2) * 2;
  const ratioMax = Math.max(1, ...points.map((point) => point.usesPerVisit ?? 0));
  const ratioTop = Math.ceil(ratioMax * 2) / 2;
  const x = (index: number) => margin.left + (index / Math.max(1, points.length - 1)) * plotWidth;
  const yCount = (value: number) => margin.top + plotHeight - (value / countTop) * plotHeight;
  const yRatio = (value: number) => margin.top + plotHeight - (value / ratioTop) * plotHeight;
  const line = (values: Array<number | null>, y: (value: number) => number) => values.map((value, index) => value == null ? null : `${x(index)},${y(value)}`).filter(Boolean).join(" ");
  const hasData = points.some((point) => point.violetUses || point.peopleSeen);

  return (
    <article className="clinical-section weekly-section">
      <div className="section-header weekly-header">
        <h2>Weekly trend</h2>
        <div className="weekly-controls">
          <div className="chart-legend"><span><i className="violet-key" />Violet uses</span><span><i className="visit-key" />People seen</span><span><i className="ratio-key" />Uses per visit</span></div>
          <label className="timeframe-control">Timeframe<select value={weeks} onChange={(event) => onWeeksChange(Number(event.target.value))}><option value="4">4 weeks</option><option value="8">8 weeks</option><option value="12">12 weeks</option></select></label>
        </div>
      </div>
      <svg className="weekly-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Weekly Violet uses, people seen, and Violet uses per visit">
        {[0, 0.25, 0.5, 0.75, 1].map((portion) => {
          const lineY = margin.top + plotHeight * portion;
          return (
            <g key={portion}>
              <line className="chart-gridline" x1={margin.left} x2={width - margin.right} y1={lineY} y2={lineY} />
              <text className="axis-label" x={margin.left - 8} y={lineY + 4} textAnchor="end">{Math.round(countTop * (1 - portion))}</text>
              <text className="axis-label ratio-axis" x={width - margin.right + 8} y={lineY + 4}>{(ratioTop * (1 - portion)).toFixed(1)}</text>
            </g>
          );
        })}
        <text className="axis-title" x="10" y={height / 2} transform={`rotate(-90 10 ${height / 2})`} textAnchor="middle">Count</text>
        <text className="axis-title ratio-axis" x={width - 8} y={height / 2} transform={`rotate(90 ${width - 8} ${height / 2})`} textAnchor="middle">Uses / visit</text>
        {points.map((point, index) => <text className="axis-label" key={point.start.toISOString()} x={x(index)} y={height - 10} textAnchor="middle">{point.label}</text>)}
        <polyline className="series-line violet-series" points={line(points.map((point) => point.violetUses), yCount)} />
        <polyline className="series-line visit-series" points={line(points.map((point) => point.peopleSeen), yCount)} />
        <polyline className="series-line ratio-series" points={line(points.map((point) => point.usesPerVisit), yRatio)} />
        {points.map((point, index) => (
          <g key={`points-${point.start.toISOString()}`}>
            <circle className="series-point violet-point" cx={x(index)} cy={yCount(point.violetUses)} r="3"><title>{`${point.label}: ${point.violetUses} Violet uses`}</title></circle>
            <circle className="series-point visit-point" cx={x(index)} cy={yCount(point.peopleSeen)} r="3"><title>{`${point.label}: ${point.peopleSeen} people seen`}</title></circle>
            {point.usesPerVisit != null && <circle className="series-point ratio-point" cx={x(index)} cy={yRatio(point.usesPerVisit)} r="3"><title>{`${point.label}: ${point.usesPerVisit.toFixed(2)} uses per visit`}</title></circle>}
          </g>
        ))}
        {!loading && !hasData && <text className="empty-chart-label" x={width / 2} y={height / 2} textAnchor="middle">No data</text>}
      </svg>
    </article>
  );
}

function HourlyChart({ points, loading }: { points: HourPoint[]; loading: boolean }) {
  const width = 720;
  const height = 220;
  const margin = { top: 12, right: 8, bottom: 28, left: 28 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const max = Math.max(1, ...points.flatMap((point) => [point.violetUses, point.visitors]));
  const group = plotWidth / points.length;
  const barWidth = Math.max(2, group / 2 - 3);
  const barHeight = (value: number) => (value / max) * plotHeight;
  const hasData = points.some((point) => point.violetUses || point.visitors);
  return (
    <svg className="hour-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Violet uses and visitors by waking hour">
      <line className="chart-gridline" x1={margin.left} x2={width - margin.right} y1={margin.top + plotHeight} y2={margin.top + plotHeight} />
      {points.map((point, index) => {
        const center = margin.left + group * index + group / 2;
        const violetHeight = barHeight(point.violetUses);
        const visitHeight = barHeight(point.visitors);
        return (
          <g key={point.hour}>
            <rect className="hour-violet" x={center - barWidth - 1} y={margin.top + plotHeight - violetHeight} width={barWidth} height={violetHeight}><title>{`${format.hour(point.hour)}: ${point.violetUses} Violet uses`}</title></rect>
            <rect className="hour-visit" x={center + 1} y={margin.top + plotHeight - visitHeight} width={barWidth} height={visitHeight}><title>{`${format.hour(point.hour)}: ${point.visitors} visitors`}</title></rect>
            {index % 2 === 0 && <text className="axis-label" x={center} y={height - 8} textAnchor="middle">{format.hour(point.hour)}</text>}
          </g>
        );
      })}
      {!loading && !hasData && <text className="empty-chart-label" x={width / 2} y={height / 2} textAnchor="middle">No data</text>}
    </svg>
  );
}

function HealthBar({ metric }: { metric: DashboardAnalytics["health"] }) {
  const percent = metric.rate == null ? null : Math.round(Math.min(100, Math.max(0, metric.rate * 100)));
  const label = metric.status === "healthy" ? "Healthy" : metric.status === "watch" ? "Watch" : metric.status === "high" ? "High" : "No data";
  return (
    <div className="health-panel">
      <div className="health-readout">
        <strong>{percent == null ? "No data" : `${percent}%`}</strong>
        {percent != null && <span>{label}</span>}
      </div>
      <div className="health-bar" role="img" aria-label={percent == null ? "Recognition health unavailable" : `${percent}% mismatch rate, ${label.toLowerCase()}`}>
        <i className="health-good" />
        <i className="health-watch" />
        <i className="health-high" />
        {percent != null && <b className="health-marker" style={{ left: `${percent}%` }} />}
      </div>
      <div className="health-scale">
        <span style={{ left: "0%" }}>0%</span>
        <span style={{ left: "30%" }}>30%</span>
        <span style={{ left: "70%" }}>70%</span>
        <span style={{ left: "100%" }}>100%</span>
      </div>
      <div className="health-count">{metric.comparableUses ? `${metric.mismatches}/${metric.comparableUses} mismatched` : "0 comparable events"}</div>
    </div>
  );
}

function MemoryChart({ points, loading }: { points: TenurePoint[]; loading: boolean }) {
  const width = 720;
  const height = 220;
  const margin = { top: 12, right: 8, bottom: 62, left: 28 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const max = Math.max(1, ...points.map((point) => point.violetUses));
  const slot = plotWidth / Math.max(1, points.length);
  const barWidth = Math.min(36, slot * 0.62);
  return (
    <svg className="memory-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Familiar people ranked by Violet uses with years known">
      <line className="chart-gridline" x1={margin.left} x2={width - margin.right} y1={margin.top + plotHeight} y2={margin.top + plotHeight} />
      {points.map((point, index) => {
        const center = margin.left + slot * index + slot / 2;
        const barHeight = (point.violetUses / max) * plotHeight;
        return (
          <g key={point.id}>
            <rect className="memory-bar" x={center - barWidth / 2} y={margin.top + plotHeight - barHeight} width={barWidth} height={barHeight}><title>{`${point.name}: ${point.violetUses} Violet uses, known ${point.yearsKnown} years`}</title></rect>
            <text className="memory-name" x={center} y={margin.top + plotHeight + 13} textAnchor="end" transform={`rotate(-45 ${center} ${margin.top + plotHeight + 13})`}>{point.name}</text>
            <text className="memory-years" x={center} y={height - 5} textAnchor="middle">{point.yearsKnown}y</text>
          </g>
        );
      })}
      {!loading && points.length === 0 && <text className="empty-chart-label" x={width / 2} y={height / 2} textAnchor="middle">No people</text>}
    </svg>
  );
}
