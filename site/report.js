// Renders data/latest.json and data/history.json.
// Every string from the data goes in through textContent, never as markup.
"use strict";

// "Other" folds grype's negligible (Debian's "unimportant") and the findings
// a scanner could not rate.
const LEVELS = [
  { key: "critical", label: "Critical", short: "Crit" },
  { key: "high", label: "High" },
  { key: "medium", label: "Medium", short: "Med" },
  { key: "low", label: "Low" },
  { key: "other", label: "Other", short: "Oth", from: ["negligible", "unknown"] },
];
const SIDES = [
  { key: "ours", label: "fyannk" },
  { key: "upstream", label: "official" },
];
const SCANNERS = [
  { key: "grype", label: "grype" },
  { key: "trivy", label: "Trivy" },
];
const DEBIAN_RELEASES = { bullseye: "11", bookworm: "12", trixie: "13", forky: "14" };

const state = { scanner: "grype", fixableOnly: false, latest: null, history: [] };
const fmt = new Intl.NumberFormat("en");

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else if (key in node && key !== "colSpan" && key !== "rowSpan" && typeof value !== "string") node[key] = value;
    else node.setAttribute(key, value);
  }
  for (const child of children.flat()) {
    if (child == null) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

function svg(tag, attrs = {}) {
  const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  return node;
}

function shortDate(iso) {
  return new Date(iso).toLocaleDateString("en", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" });
}

function isAlpine(image) {
  return image.variant.startsWith("alpine");
}

function osLabel(image) {
  if (isAlpine(image)) return `Alpine ${image.variant.slice("alpine".length)}`;
  const release = DEBIAN_RELEASES[image.variant];
  return release ? `Debian ${release} (${image.variant})` : `Debian ${image.variant}`;
}

// Newest major first, the default Debian base before Alpine within it.
function orderedImages() {
  return [...state.latest.images].sort((a, b) => Number(b.major) - Number(a.major) || isAlpine(a) - isAlpine(b));
}

function isStable(image) {
  return /^\d+(\.\d+)*$/.test(image.version);
}

// Ours is missing when it has not been published yet; upstream exists, so a
// miss there is a failed fetch.
function unavailable(side, info) {
  if (info?.error === "not available") return side === "ours" ? "not published yet" : "unavailable this run";
  return info?.error ?? "no data";
}

function status(text) {
  return el("span", { class: "status stale", text });
}

function sourceLabel(side) {
  return el("span", { class: "source" }, el("span", { class: `key key-dot ${side.key}`, "aria-hidden": "true" }), side.label);
}

// --- Header -----------------------------------------------------------------

function utc(iso) {
  return `${new Date(iso).toLocaleString("en", { dateStyle: "medium", timeStyle: "short", hourCycle: "h23", timeZone: "UTC" })} UTC`;
}

// When the data was produced, from what, and with which tools: one row each.
function renderMeta() {
  const { generated, upstream_revision: rev, tools } = state.latest;
  const row = (label, ...cells) => el("tr", {}, el("th", { scope: "row", text: label }), ...cells);
  const tool = (name, version, database) => row(name,
    el("td", { class: "version", text: version }),
    el("td", {}, database));
  document.getElementById("meta").replaceChildren(el("table", { class: "meta-table" },
    el("caption", { class: "vh", text: "About this scan" }),
    el("tbody", {},
      row("Last scan", el("td", { colspan: "2" }, el("time", { datetime: generated, text: utc(generated) }))),
      row("Upstream recipe", el("td", { colspan: "2" },
        el("a", { href: `https://github.com/docker-library/postgres/tree/${rev}` }, el("code", { text: rev.slice(0, 7) })),
        " docker-library/postgres")),
    ),
    el("tbody", {},
      el("tr", { class: "head" },
        el("th", { scope: "col", text: "Tool" }),
        el("th", { scope: "col", text: "Version" }),
        el("th", { scope: "col", text: "Advisory database" })),
      tool("grype", tools.grype, databaseAge(tools.grype_db, generated)),
      tool("Trivy", tools.trivy, databaseAge(tools.trivy_db, generated)),
      tool("Syft", tools.syft, el("span", { class: "muted", text: "none, inventory only" })),
    ),
  ));
}

// A database more than two days older than the scan has missed updates both
// publish daily, so the result is flagged rather than shown as current.
const STALE_DB_MS = 2 * 24 * 60 * 60 * 1000;

function databaseAge(built, scanned) {
  if (!built) return status("build time unknown");
  const time = el("time", { datetime: built, text: `built ${utc(built)}` });
  if (new Date(scanned) - new Date(built) <= STALE_DB_MS) return time;
  return el("span", { class: "status warn" }, time, ", more than two days before the scan");
}

// --- Severity squares ---------------------------------------------------------

function levelCounts(summary, level) {
  const keys = level.from ?? [level.key];
  const sum = (bucket) => keys.reduce((n, k) => n + (bucket?.[k] ?? 0), 0);
  return { fixable: sum(summary.fixable_severity), total: sum(summary.severity) };
}

// One cell: findings with a fix / all findings, filled with the severity's
// colour when there is any finding at that level.
function square(level, { fixable, total }) {
  if (total === 0) {
    return el("td", { class: "sev" }, el("span", { class: "sq none" },
      el("span", { "aria-hidden": "true", text: "–" }), el("span", { class: "vh", text: "none" })));
  }
  return el("td", { class: "sev" }, el("span", { class: `sq sev-${level}${fixable ? " has-fix" : ""}` },
    el("span", { "aria-hidden": "true", text: `${fmt.format(fixable)}/${fmt.format(total)}` }),
    el("span", { class: "vh", text: `${fmt.format(fixable)} of ${fmt.format(total)} with a fix` })));
}

function allCell(summary) {
  return el("td", { class: "num all" },
    el("span", { "aria-hidden": "true", text: `${fmt.format(summary.fixable)}/${fmt.format(summary.total)}` }),
    el("span", { class: "vh", text: `${fmt.format(summary.fixable)} of ${fmt.format(summary.total)} with a fix` }));
}

function severityCells(summary) {
  return [...LEVELS.map((level) => square(level.key, levelCounts(summary, level))), allCell(summary)];
}

// Narrow cards show the short labels; the full one stays for screen readers.
function severityHeads() {
  return [
    ...LEVELS.map((level) => el("th", { scope: "col", class: "sev" },
      el("span", { class: "long", text: level.label }),
      el("span", { class: "short", "aria-hidden": "true", text: level.short ?? level.label }))),
    el("th", { scope: "col", class: "num all", text: "All" }),
  ];
}

function renderKey() {
  const sample = (level, text) => el("span", { class: `sq sev-${level}`, "aria-hidden": "true", text });
  document.getElementById("squares-key").replaceChildren(
    "Each cell reads ", el("strong", { text: "with a fix / all findings" }), " at that severity: ",
    sample("critical", "0/1"), " is one critical finding, without a fix yet; ",
    sample("high", "10/10"), " is ten high findings, all of which a rebuild would clear. ",
    "Other is grype's negligible and anything a scanner could not rate.",
  );
}

// --- Latest stable ------------------------------------------------------------

function stableImages() {
  const stable = state.latest.images.filter(isStable);
  if (stable.length === 0) return null;
  const major = Math.max(...stable.map((i) => Number(i.major)));
  const ofMajor = stable.filter((i) => Number(i.major) === major);
  return {
    major,
    version: ofMajor[0].version,
    debian: ofMajor.find((i) => !isAlpine(i)) ?? null,
    alpine: ofMajor.find(isAlpine) ?? null,
  };
}

function renderStable() {
  const stable = stableImages();
  const container = document.getElementById("stable");
  if (!stable) {
    container.replaceChildren(el("p", { class: "muted", text: "No stable release has been scanned yet." }));
    return;
  }
  document.getElementById("stable-title").textContent = `Latest stable: PostgreSQL ${stable.version}`;
  const scanner = SCANNERS.find((s) => s.key === state.scanner);
  container.replaceChildren(...[stable.debian, stable.alpine].filter(Boolean)
    .map((image) => imageCard(image, osLabel(image), [scanner])));
}

// One card per image: its sides, each scanned by the given scanners. With a
// single scanner the side names its row; with several, the side heads a
// group of scanner rows. Cards size themselves, so they tile on wide screens
// and stack on narrow ones.
function imageCard(image, title, scanners) {
  const single = scanners.length === 1;
  const columns = 1 + LEVELS.length + 1;
  const head = el("thead", {}, el("tr", {},
    el("th", { scope: "col", text: single ? "Image" : "Scanner" }),
    ...severityHeads(),
  ));
  const bodies = SIDES.map((side) => {
    const info = image[side.key];
    const body = el("tbody");
    if (!single) body.append(el("tr", { class: "side" }, el("th", { scope: "rowgroup", colspan: String(columns) }, sourceLabel(side))));
    if (!info?.scans) {
      body.append(el("tr", {},
        el("th", { scope: "row" }, single ? sourceLabel(side) : ""),
        el("td", { colspan: String(columns - 1) }, status(unavailable(side.key, info)))));
      return body;
    }
    for (const scanner of scanners) {
      const summary = info.scans[scanner.key];
      body.append(el("tr", {},
        el("th", { scope: "row" }, single ? sourceLabel(side) : el("span", { class: "scanner", text: scanner.label })),
        ...(summary ? severityCells(summary) : [el("td", { colspan: String(columns - 1) }, status("not scanned"))])));
    }
    return body;
  });
  return el("article", { class: "card image-card" },
    el("h3", { text: title }),
    el("div", { class: "table-wrap" }, el("table", { class: "severity-table" }, head, ...bodies)));
}

// --- Trend chart --------------------------------------------------------------------

function chartSeries() {
  const stable = stableImages();
  if (!stable) return [];
  const series = [];
  for (const side of SIDES) {
    for (const [os, image] of [["Debian", stable.debian], ["Alpine", stable.alpine]]) {
      if (!image) continue;
      series.push({ id: `${side.key}-${os}`, side: side.key, alt: os === "Alpine", name: image.name, label: `${side.label} · ${os}` });
    }
  }
  return series;
}

function lineKey(series) {
  return el("span", { class: `key key-line ${series.side}${series.alt ? " alt" : ""}`, "aria-hidden": "true" });
}

function renderLegend(series) {
  document.getElementById("legend").replaceChildren(...series.map((s) => el("li", {}, lineKey(s), s.label)));
}

function renderHistoryTable(series, points, metric) {
  document.getElementById("history-table").replaceChildren(
    el("caption", { text: `${metric}, ${SCANNERS.find((s) => s.key === state.scanner).label}` }),
    el("thead", {}, el("tr", {},
      el("th", { scope: "col", text: "Date" }),
      ...series.map((s) => el("th", { scope: "col", class: "num", text: s.label })),
    )),
    el("tbody", {}, [...points].reverse().map((p) => el("tr", {},
      el("td", { text: shortDate(p.date) }),
      ...series.map((s) => el("td", { class: "num", text: p.values[s.id] == null ? "–" : fmt.format(p.values[s.id]) })),
    ))),
  );
}

function niceMax(value) {
  if (value <= 4) return 4;
  const step = 10 ** Math.floor(Math.log10(value));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * step >= value) return m * step;
  return 10 * step;
}

// End labels keep at least `gap` pixels apart, pushed down in order, so
// series ending on the same value stay readable.
function spreadLabels(labels, gap, max) {
  labels.sort((a, b) => a.y - b.y);
  for (let i = 1; i < labels.length; i++) labels[i].y = Math.max(labels[i].y, labels[i - 1].y + gap);
  const overflow = labels.length ? labels[labels.length - 1].y - max : 0;
  if (overflow > 0) for (const label of labels) label.y -= overflow;
  return labels;
}

function renderChart() {
  const container = document.getElementById("chart");
  const series = chartSeries();
  const stable = stableImages();
  const metricKey = state.fixableOnly ? "fixable" : "total";
  const metric = state.fixableOnly ? "Findings with a fix" : "All findings";
  document.getElementById("trend-title").textContent = stable ? `PostgreSQL ${stable.major} over time` : "Over time";
  document.getElementById("trend-note").textContent = `${metric}, one point per nightly scan.`;
  renderLegend(series);

  const points = state.history
    .map((h) => ({
      date: h.date,
      values: Object.fromEntries(series.map((s) => [s.id, h.images?.[s.name]?.[s.side]?.[state.scanner]?.[metricKey] ?? null])),
    }))
    .filter((p) => Object.values(p.values).some((v) => v != null));
  renderHistoryTable(series, points, metric);

  if (points.length < 2) {
    container.replaceChildren(el("p", { class: "empty", text: points.length === 0
      ? "The trend starts with the first nightly scan."
      : "The trend line appears after the second nightly scan." }));
    return;
  }

  const width = Math.max(container.clientWidth, 320);
  // Taller on wide screens, so the lines do not flatten out.
  const height = Math.round(Math.min(440, Math.max(260, width * 0.3)));
  // Narrow charts drop the end labels for room; the legend names the lines.
  const endLabels = width >= 560;
  const m = { top: 16, right: endLabels ? 150 : 12, bottom: 28, left: 44 };
  const plotW = width - m.left - m.right;
  const plotH = height - m.top - m.bottom;
  const values = points.flatMap((p) => Object.values(p.values).filter((v) => v != null));
  const yMax = niceMax(Math.max(...values));
  const x = (i) => m.left + (i / (points.length - 1)) * plotW;
  const y = (v) => m.top + plotH - (v / yMax) * plotH;

  const root = svg("svg", { viewBox: `0 0 ${width} ${height}`, role: "img", tabindex: "0",
    "aria-label": `${metric} over ${points.length} scans, ${series.map((s) => s.label).join(", ")}. Use the arrow keys to read each scan.` });

  for (let i = 0; i <= 4; i++) {
    const v = (yMax / 4) * i;
    root.append(svg("line", { class: i === 0 ? "baseline" : "grid", x1: m.left, x2: m.left + plotW, y1: y(v), y2: y(v) }));
    const label = svg("text", { class: "tick", x: m.left - 8, y: y(v) + 4, "text-anchor": "end" });
    label.textContent = fmt.format(v);
    root.append(label);
  }
  const ticks = new Set(endLabels ? [0, points.length - 1, Math.round((points.length - 1) / 2)] : [0, points.length - 1]);
  for (const i of ticks) {
    const label = svg("text", { class: "tick", x: x(i), y: height - 8, "text-anchor": i === 0 ? "start" : i === points.length - 1 ? "end" : "middle" });
    label.textContent = shortDate(points[i].date);
    root.append(label);
  }

  // A night without data for a series breaks its line instead of joining
  // across the gap.
  const ends = [];
  for (const s of series) {
    let d = "";
    let pen = false;
    let lastIndex = -1;
    points.forEach((p, i) => {
      const v = p.values[s.id];
      if (v == null) { pen = false; return; }
      d += `${pen ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`;
      pen = true;
      lastIndex = i;
    });
    if (lastIndex < 0) continue;
    root.append(svg("path", { class: `series ${s.side}${s.alt ? " alt" : ""}`, d }));
    const v = points[lastIndex].values[s.id];
    root.append(svg("circle", { class: `dot ${s.side}`, cx: x(lastIndex), cy: y(v), r: 4 }));
    ends.push({ x: x(lastIndex), y: y(v) + 4, text: `${s.label} ${fmt.format(v)}` });
  }
  for (const end of endLabels ? spreadLabels(ends, 14, height - m.bottom) : []) {
    const label = svg("text", { class: "end-label", x: end.x + 10, y: end.y });
    label.textContent = end.text;
    root.append(label);
  }

  const crosshair = svg("line", { class: "crosshair", y1: m.top, y2: m.top + plotH, visibility: "hidden" });
  root.append(crosshair);
  const markers = series.map((s) => {
    const c = svg("circle", { class: `dot ${s.side}`, r: 4, visibility: "hidden" });
    root.append(c);
    return c;
  });

  const tooltip = el("div", { class: "tooltip", hidden: true, role: "status" });
  const last = points.length - 1;
  let active = null;
  const show = (i) => {
    active = i;
    const p = points[i];
    crosshair.setAttribute("x1", x(i));
    crosshair.setAttribute("x2", x(i));
    crosshair.setAttribute("visibility", "visible");
    series.forEach((s, k) => {
      const v = p.values[s.id];
      markers[k].setAttribute("visibility", v == null ? "hidden" : "visible");
      if (v != null) {
        markers[k].setAttribute("cx", x(i));
        markers[k].setAttribute("cy", y(v));
      }
    });
    tooltip.replaceChildren(
      el("div", { class: "date", text: shortDate(p.date) }),
      ...series.map((s) => el("div", { class: "row" }, lineKey(s),
        el("strong", { text: p.values[s.id] == null ? "–" : fmt.format(p.values[s.id]) }), s.label)),
    );
    tooltip.hidden = false;
    const scale = container.clientWidth / width;
    const left = x(i) * scale;
    tooltip.style.top = `${m.top}px`;
    tooltip.style.left = left > container.clientWidth / 2 ? "" : `${left + 12}px`;
    tooltip.style.right = left > container.clientWidth / 2 ? `${container.clientWidth - left + 12}px` : "";
  };
  const hide = () => {
    active = null;
    crosshair.setAttribute("visibility", "hidden");
    markers.forEach((c) => c.setAttribute("visibility", "hidden"));
    tooltip.hidden = true;
  };
  root.addEventListener("pointermove", (event) => {
    const box = root.getBoundingClientRect();
    const px = ((event.clientX - box.left) / box.width) * width;
    const i = Math.round(((px - m.left) / plotW) * (points.length - 1));
    show(Math.min(last, Math.max(0, i)));
  });
  root.addEventListener("pointerleave", hide);
  root.addEventListener("blur", hide);
  root.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault();
      const step = event.key === "ArrowLeft" ? -1 : 1;
      show(Math.min(last, Math.max(0, (active ?? last) + (active == null ? 0 : step))));
    } else if (event.key === "Escape") hide();
  });
  root.addEventListener("focus", () => show(last));

  container.replaceChildren(root, tooltip);
}

// --- Every image ----------------------------------------------------------------------

function renderAll() {
  document.getElementById("all").replaceChildren(...orderedImages()
    .map((image) => imageCard(image, `${image.version} · ${osLabel(image)}`, SCANNERS)));
}

// --- Tags ---------------------------------------------------------------------------

function renderTags() {
  const repo = state.latest.images.find((i) => i.ours?.ref)?.ours.ref.replace(/:[^:/]*$/, "") ?? "";
  const head = el("thead", {}, el("tr", {},
    el("th", { scope: "col", text: "PostgreSQL" }),
    el("th", { scope: "col", text: "Base" }),
    el("th", { scope: "col", text: "Tags" }),
    el("th", { scope: "col", text: "Digest" }),
    el("th", { scope: "col", text: "Data" }),
  ));
  const body = el("tbody", {}, orderedImages().map((image) => {
    const ours = image.ours;
    const published = ours && !ours.error && ours.digest;
    const tags = el("td", { class: "wrap" }, (image.tags ?? []).map((tag) => el("code", { class: "tag", text: tag })));
    const digest = published
      ? el("td", {}, el("code", { title: `${repo}@${ours.digest}`, text: `${ours.digest.slice(0, 19)}…` }))
      : el("td", {}, status(unavailable("ours", ours)));
    const data = el("td", { class: "links" },
      published ? el("a", { href: `sboms/${encodeURIComponent(image.name)}.spdx.json`, text: "SBOM" }) : null,
      published ? " · " : null,
      el("a", { href: `data/images/${encodeURIComponent(image.name)}.json`, text: "findings" }));
    tags.dataset.label = "Tags";
    digest.dataset.label = "Digest";
    data.dataset.label = "Data";
    return el("tr", {},
      el("th", { scope: "row", class: "version", text: image.version }),
      el("td", { class: "os", text: osLabel(image) }),
      tags, digest, data);
  }));
  document.getElementById("tags").replaceChildren(
    el("caption", { text: `Tags on ${repo || "ghcr.io/fyannk/postgres"} and docker.io/fyannk/postgres` }), head, body);
}

// --- Wiring ---------------------------------------------------------------------------

function render() {
  renderStable();
  renderChart();
  renderAll();
}

async function main() {
  try {
    const [latest, history] = await Promise.all([
      fetch("data/latest.json").then((r) => { if (!r.ok) throw new Error(`latest.json: ${r.status}`); return r.json(); }),
      fetch("data/history.json").then((r) => (r.ok ? r.json() : [])).catch(() => []),
    ]);
    state.latest = latest;
    state.history = Array.isArray(history) ? history : [];
  } catch (error) {
    document.getElementById("meta").textContent = `The scan data could not be loaded (${error.message}).`;
    return;
  }
  renderMeta();
  renderKey();
  render();
  renderTags();

  const form = document.getElementById("filters");
  form.addEventListener("change", () => {
    state.scanner = form.elements.scanner.value;
    renderStable();
    renderChart();
  });
  document.getElementById("fixable").addEventListener("change", (event) => {
    state.fixableOnly = event.target.checked;
    renderChart();
  });
  let width = document.getElementById("chart").clientWidth;
  new ResizeObserver(([entry]) => {
    if (Math.abs(entry.contentRect.width - width) < 8) return;
    width = entry.contentRect.width;
    renderChart();
  }).observe(document.getElementById("chart"));
}

main();
