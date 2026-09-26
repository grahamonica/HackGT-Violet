"use client";

import type { DashboardAnalytics, HourPoint, TenurePoint, WeekPoint } from "@/lib/analytics";
import { format } from "@/lib/date";

type Props = { analytics: DashboardAnalytics; loading: boolean; weeks: number; onWeeksChange: (weeks: number) => void };

export function AnalyticsDashboard({ analytics, loading, weeks, onWeeksChange }: Props) {
  return (
    <section className="analytics-column" aria-label="Patient analytics">
      <WeeklyChart points={analytics.weeks} loading={loading} weeks={weeks} onWeeksChange={onWeeksChange} />
      <div className="signal-grid">
        <HourlyChart points={analytics.hours} loading={loading} />
        <HealthDial metric={analytics.health} />
        <MemoryChart points={analytics.tenure} loading={loading} />
      </div>
    </section>
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
  const width = 310;
  const height = 215;
  const margin = { top: 8, right: 8, bottom: 27, left: 24 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const max = Math.max(1, ...points.flatMap((point) => [point.violetUses, point.visitors]));
  const group = plotWidth / points.length;
  const barWidth = Math.max(2, group / 2 - 2);
  const barHeight = (value: number) => (value / max) * plotHeight;
  const hasData = points.some((point) => point.violetUses || point.visitors);
  return (
    <article className="clinical-section signal-section">
      <div className="section-header"><h2>Time of day</h2><div className="chart-legend compact"><span><i className="violet-key" />Violet</span><span><i className="visit-key" />Visitors</span></div></div>
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
              {index % 4 === 0 && <text className="axis-label" x={center} y={height - 8} textAnchor="middle">{format.hour(point.hour)}</text>}
            </g>
          );
        })}
        {!loading && !hasData && <text className="empty-chart-label" x={width / 2} y={height / 2} textAnchor="middle">No data</text>}
      </svg>
    </article>
  );
}

function HealthDial({ metric }: { metric: DashboardAnalytics["health"] }) {
  const percent = metric.rate == null ? null : Math.round(metric.rate * 100);
  const angle = percent == null ? 0 : -90 + (Math.min(100, Math.max(0, percent)) / 100) * 180;
  const radians = (angle * Math.PI) / 180;
  const label = metric.status === "healthy" ? "Healthy" : metric.status === "watch" ? "Watch" : metric.status === "high" ? "High" : "No data";
  return (
    <article className="clinical-section signal-section health-section">
      <div className="section-header"><h2>Recognition health</h2></div>
      <div className="dial-wrap">
        <svg className="dial" viewBox="0 0 220 132" role="img" aria-label={percent == null ? "Recognition health unavailable" : `${percent}% mismatch rate`}>
          <path className="dial-track" d="M20 110 A90 90 0 0 1 200 110" pathLength="100" />
          <path className="dial-good" d="M20 110 A90 90 0 0 1 200 110" pathLength="100" />
          <path className="dial-watch" d="M20 110 A90 90 0 0 1 200 110" pathLength="100" />
          <path className="dial-high" d="M20 110 A90 90 0 0 1 200 110" pathLength="100" />
          {percent != null && <line className="dial-needle" x1="110" y1="110" x2={110 + Math.cos(radians) * 67} y2={110 + Math.sin(radians) * 67} />}
          <circle className="dial-center" cx="110" cy="110" r="7" />
        </svg>
        <div className="dial-value"><strong>{percent == null ? "—" : `${percent}%`}</strong><span>{label}</span></div>
      </div>
      <div className="dial-count">{metric.comparableUses ? `${metric.mismatches}/${metric.comparableUses} mismatched` : "0 comparable events"}</div>
    </article>
  );
}

function MemoryChart({ points, loading }: { points: TenurePoint[]; loading: boolean }) {
  const width = 330;
  const height = 240;
  const margin = { top: 12, right: 8, bottom: 72, left: 26 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const max = Math.max(1, ...points.map((point) => point.violetUses));
  const slot = plotWidth / Math.max(1, points.length);
  const barWidth = Math.min(24, slot * 0.62);
  return (
    <article className="clinical-section signal-section memory-section">
      <div className="section-header"><h2>Memory by person</h2></div>
      <svg className="memory-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Familiar people ranked by Violet uses with years known">
        <line className="chart-gridline" x1={margin.left} x2={width - margin.right} y1={margin.top + plotHeight} y2={margin.top + plotHeight} />
        {points.map((point, index) => {
          const center = margin.left + slot * index + slot / 2;
          const barHeight = (point.violetUses / max) * plotHeight;
          return (
            <g key={point.id}>
              <rect className="memory-bar" x={center - barWidth / 2} y={margin.top + plotHeight - barHeight} width={barWidth} height={barHeight}><title>{`${point.name}: ${point.violetUses} Violet uses, known ${point.yearsKnown} years`}</title></rect>
              <text className="memory-name" x={center} y={margin.top + plotHeight + 13} textAnchor="end" transform={`rotate(-55 ${center} ${margin.top + plotHeight + 13})`}>{point.name}</text>
              <text className="memory-years" x={center} y={height - 5} textAnchor="middle">{point.yearsKnown}y</text>
            </g>
          );
        })}
        {!loading && points.length === 0 && <text className="empty-chart-label" x={width / 2} y={height / 2} textAnchor="middle">No people</text>}
      </svg>
    </article>
  );
}
