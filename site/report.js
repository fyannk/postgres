// Renders data/latest.json, data/history.json and data/images/<name>.json.
// Every string from the data goes in through textContent, never as markup.
"use strict";

const SEVERITIES = ["critical", "high", "medium", "low", "negligible", "unknown"];
const SIDES = [
  { key: "ours", label: "Ours" },
  { key: "upstream", label: "Upstream" },
];
const SCANNER_LABEL = { grype: "grype", trivy: "Trivy" };

const state = { scanner: "grype", fixableOnly: false, latest: null, history: [], details: new Map() };
const fmt = new Intl.NumberFormat("en");

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else if (key in node && key !== "colSpan" && typeof value !== "string") node[key] = value;
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

function key(side, shape = "dot") {
  return el("span", { class: `key key-${shape} ${side}`, "aria-hidden": "true" });
}

function scans(image, side) {
  return image[side]?.scans?.[state.scanner] ?? null;
}

function critHigh(summary, fixableOnly = false) {
  const s = fixableOnly ? summary.fixable_severity : summary.severity;
  return s.critical + s.high;
}

// Ours is missing when it has not been published yet; upstream exists, so a
// miss there is a failed fetch (a Docker Hub rate limit, typically).
function unavailable(side, info) {
  if (info?.error === "not available") return side === "ours" ? "not published yet" : "unavailable this run";
  return info?.error ?? "no data";
}

function shortDate(iso) {
  return new Date(iso).toLocaleDateString("en", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" });
}

// --- Header -----------------------------------------------------------------

function renderMeta() {
  const { generated, upstream_revision: rev, tools } = state.latest;
  const meta = document.getElementById("meta");
  meta.replaceChildren(
    "Last scan ",
    el("time", { datetime: generated, text: new Date(generated).toLocaleString("en", { dateStyle: "medium", timeStyle: "short", timeZone: "UTC" }) + " UTC" }),
    " · upstream recipe ",
    el("a", { href: `https://github.com/docker-library/postgres/tree/${rev}`, text: rev.slice(0, 7) }),
    ` · grype ${tools.grype}, Trivy ${tools.trivy}, Syft ${tools.syft}`,
  );
}

// --- Stat tiles ---------------------------------------------------------------

function totals(side) {
  const out = { images: 0, total: 0, fixable: 0, critHigh: 0, go: 0 };
  for (const image of state.latest.images) {
    // Only pairs where both sides were scanned, so the two columns compare
    // the same set of images.
    const own = scans(image, side);
    if (!own || !scans(image, side === "ours" ? "upstream" : "ours")) continue;
    out.images += 1;
    out.total += own.total;
    out.fixable += own.fixable;
    out.critHigh += critHigh(own, state.fixableOnly);
    out.go += own.go;
  }
  return out;
}

function renderTiles() {
  const ours = totals("ours");
  const upstream = totals("upstream");
  const tiles = document.getElementById("tiles");
  const scope = document.getElementById("scope");
  if (ours.images === 0) {
    scope.textContent = "";
    tiles.replaceChildren(el("p", { class: "muted", text: "No image pair has been scanned on both sides yet. Our images appear here after their first publish." }));
    return;
  }
  scope.textContent = `Summed across ${ours.images} image${ours.images === 1 ? "" : "s"} scanned on both sides, with ${SCANNER_LABEL[state.scanner]}.`;
  const tile = (title, a, b) => el("div", { class: "tile" },
    el("h3", { text: title }),
    el("dl", {},
      el("dt", {}, key("ours"), "Ours"), el("dd", { class: "big", text: fmt.format(a) }),
      el("dt", {}, key("upstream"), "Upstream"), el("dd", { class: "small", text: fmt.format(b) }),
    ),
  );
  tiles.replaceChildren(
    tile("Findings with a fix", ours.fixable, upstream.fixable),
    tile(state.fixableOnly ? "Critical and high with a fix" : "Critical and high", ours.critHigh, upstream.critHigh),
    tile("In bundled Go binaries", ours.go, upstream.go),
    tile("All findings", ours.total, upstream.total),
  );
}

// --- Overview table -------------------------------------------------------------

function renderOverview() {
  const table = document.getElementById("overview");
  const caption = el("caption", { text: `Findings per image, ${SCANNER_LABEL[state.scanner]}${state.fixableOnly ? ", critical and high counted only with a fix" : ""}` });
  const cols = [["All", "total"], ["With a fix", "fixable"], ["Crit. + high", "ch"], ["Go", "go"]];
  const head = el("thead", {},
    el("tr", { class: "group" },
      el("th", { colspan: "2" }),
      ...SIDES.map((s) => el("th", { colspan: String(cols.length), scope: "colgroup" }, el("span", {}, key(s.key), s.label))),
    ),
    el("tr", {},
      el("th", { scope: "col", text: "Image" }),
      el("th", { scope: "col", text: "Version" }),
      ...SIDES.flatMap(() => cols.map(([label]) => el("th", { scope: "col", class: "num", text: label }))),
    ),
  );
  const body = el("tbody");
  for (const image of state.latest.images) {
    const row = el("tr", {},
      el("th", { scope: "row" }, el("a", { href: `#image-${image.name}`, text: image.name })),
      el("td", { text: image.version }),
    );
    for (const side of SIDES) {
      const s = scans(image, side.key);
      if (!s) {
        row.append(el("td", { class: "na", colspan: String(cols.length), text: unavailable(side.key, image[side.key]) }));
        continue;
      }
      const values = { total: s.total, fixable: s.fixable, ch: critHigh(s, state.fixableOnly), go: s.go };
      for (const [, k] of cols) row.append(el("td", { class: "num", text: fmt.format(values[k]) }));
    }
    body.append(row);
  }
  table.replaceChildren(caption, head, body);
}

// --- Trend chart ------------------------------------------------------------------

function renderHistoryTable(points) {
  const table = document.getElementById("history-table");
  table.replaceChildren(
    el("caption", { text: `Findings with a fix, summed across images, ${SCANNER_LABEL[state.scanner]}` }),
    el("thead", {}, el("tr", {},
      el("th", { scope: "col", text: "Date" }),
      el("th", { scope: "col", class: "num", text: "Ours" }),
      el("th", { scope: "col", class: "num", text: "Upstream" }),
      el("th", { scope: "col", class: "num", text: "Images" }),
    )),
    el("tbody", {}, [...points].reverse().map((p) => el("tr", {},
      el("td", { text: shortDate(p.date) }),
      el("td", { class: "num", text: fmt.format(p.ours) }),
      el("td", { class: "num", text: fmt.format(p.upstream) }),
      el("td", { class: "num", text: String(p.images) }),
    ))),
  );
}

function niceMax(value) {
  if (value <= 4) return 4;
  const step = 10 ** Math.floor(Math.log10(value));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * step >= value) return m * step;
  return 10 * step;
}

function renderChart() {
  const container = document.getElementById("chart");
  const points = state.history
    .filter((h) => h.ours?.[state.scanner] && h.upstream?.[state.scanner])
    .map((h) => ({
      date: h.date,
      ours: h.ours[state.scanner].fixable,
      upstream: h.upstream[state.scanner].fixable,
      images: Math.min(h.ours[state.scanner].images, h.upstream[state.scanner].images),
    }))
    .filter((p) => p.images > 0);
  renderHistoryTable(points);

  if (points.length < 2) {
    container.replaceChildren(el("p", { class: "empty", text: points.length === 0
      ? "The trend starts with the first scan where both sides are available."
      : "The trend line appears after the second nightly scan." }));
    return;
  }

  const width = Math.max(container.clientWidth, 320);
  const height = 260;
  const m = { top: 16, right: 92, bottom: 28, left: 44 };
  const plotW = width - m.left - m.right;
  const plotH = height - m.top - m.bottom;
  const yMax = niceMax(Math.max(...points.map((p) => Math.max(p.ours, p.upstream))));
  const x = (i) => m.left + (points.length === 1 ? plotW / 2 : (i / (points.length - 1)) * plotW);
  const y = (v) => m.top + plotH - (v / yMax) * plotH;

  const root = svg("svg", { viewBox: `0 0 ${width} ${height}`, role: "img", tabindex: "0",
    "aria-label": `Findings with a fix over ${points.length} scans. Use the arrow keys to read each scan.` });

  for (let i = 0; i <= 4; i++) {
    const v = (yMax / 4) * i;
    root.append(svg("line", { class: i === 0 ? "baseline" : "grid", x1: m.left, x2: m.left + plotW, y1: y(v), y2: y(v) }));
    const label = svg("text", { class: "tick", x: m.left - 8, y: y(v) + 4, "text-anchor": "end" });
    label.textContent = fmt.format(v);
    root.append(label);
  }
  const ticks = new Set([0, points.length - 1, Math.round((points.length - 1) / 2)]);
  for (const i of ticks) {
    const label = svg("text", { class: "tick", x: x(i), y: height - 8, "text-anchor": i === 0 ? "start" : i === points.length - 1 ? "end" : "middle" });
    label.textContent = shortDate(points[i].date);
    root.append(label);
  }

  const last = points.length - 1;
  const ends = [];
  for (const side of SIDES) {
    const d = points.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(p[side.key]).toFixed(1)}`).join("");
    root.append(svg("path", { class: `series ${side.key}`, d }));
    root.append(svg("circle", { class: `dot ${side.key}`, cx: x(last), cy: y(points[last][side.key]), r: 4 }));
    ends.push({ side, y: y(points[last][side.key]) });
  }
  // End labels only when they do not collide; the legend carries identity
  // either way.
  if (Math.abs(ends[0].y - ends[1].y) >= 14) {
    for (const end of ends) {
      const label = svg("text", { class: "end-label", x: x(last) + 10, y: end.y + 4 });
      label.textContent = `${end.side.label} ${fmt.format(points[last][end.side.key])}`;
      root.append(label);
    }
  }

  const crosshair = svg("line", { class: "crosshair", y1: m.top, y2: m.top + plotH, visibility: "hidden" });
  root.append(crosshair);
  const markers = SIDES.map((side) => {
    const c = svg("circle", { class: `dot ${side.key}`, r: 4, visibility: "hidden" });
    root.append(c);
    return c;
  });

  const tooltip = el("div", { class: "tooltip", hidden: true, role: "status" });
  let active = null;
  const show = (i) => {
    active = i;
    const p = points[i];
    crosshair.setAttribute("x1", x(i));
    crosshair.setAttribute("x2", x(i));
    crosshair.setAttribute("visibility", "visible");
    SIDES.forEach((side, k) => {
      markers[k].setAttribute("cx", x(i));
      markers[k].setAttribute("cy", y(p[side.key]));
      markers[k].setAttribute("visibility", "visible");
    });
    tooltip.replaceChildren(
      el("div", { class: "date", text: shortDate(p.date) }),
      ...SIDES.map((side) => el("div", { class: "row" }, key(side.key, "line"), el("strong", { text: fmt.format(p[side.key]) }), side.label)),
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
    show(Math.min(points.length - 1, Math.max(0, i)));
  });
  root.addEventListener("pointerleave", hide);
  root.addEventListener("blur", hide);
  root.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault();
      const step = event.key === "ArrowLeft" ? -1 : 1;
      show(Math.min(points.length - 1, Math.max(0, (active ?? last) + (active == null ? 0 : step))));
    } else if (event.key === "Escape") hide();
  });
  root.addEventListener("focus", () => show(last));

  container.replaceChildren(root, tooltip);
}

// --- Image detail -------------------------------------------------------------------

function findingTable(rows, caption, showBoth) {
  const head = el("tr", {},
    el("th", { scope: "col", text: "Advisory" }),
    el("th", { scope: "col", text: "Severity" }),
    el("th", { scope: "col", text: "Package" }),
    ...(showBoth
      ? [el("th", { scope: "col", text: "Ours" }), el("th", { scope: "col", text: "Upstream" })]
      : [el("th", { scope: "col", text: "Installed" })]),
    el("th", { scope: "col", text: "Fixed in" }),
  );
  const body = rows.map(({ finding, ours, upstream }) => el("tr", {},
    el("td", {}, el("a", { href: `https://osv.dev/vulnerability/${encodeURIComponent(finding.id)}`, text: finding.id })),
    el("td", { text: finding.severity }),
    el("td", { text: finding.package }),
    ...(showBoth
      ? [el("td", { text: ours?.version ?? "" }), el("td", { text: upstream?.version ?? "" })]
      : [el("td", { text: finding.version })]),
    el("td", { class: "wrap", text: finding.fixed_in || (finding.state ? `no fix (${finding.state})` : "no fix") }),
  ));
  return el("div", { class: "table-wrap" }, el("table", {}, el("caption", { text: caption }), el("thead", {}, head), el("tbody", {}, body)));
}

function compare(detail) {
  const pick = (side) => {
    const list = detail[side]?.findings?.[state.scanner] ?? null;
    if (!list) return null;
    return new Map(list.filter((f) => !state.fixableOnly || f.fixed).map((f) => [`${f.id}\u0000${f.package}`, f]));
  };
  const ours = pick("ours");
  const upstream = pick("upstream");
  const rank = (f) => SEVERITIES.indexOf(f.severity);
  const sort = (rows) => rows.sort((a, b) => rank(a.finding) - rank(b.finding) || a.finding.id.localeCompare(b.finding.id));
  if (!ours || !upstream) return { ours, upstream };
  const onlyUpstream = [], onlyOurs = [], both = [];
  for (const [k, f] of upstream) (ours.has(k) ? both : onlyUpstream).push({ finding: f, ours: ours.get(k), upstream: f });
  for (const [k, f] of ours) if (!upstream.has(k)) onlyOurs.push({ finding: f, ours: f });
  return { ours, upstream, onlyUpstream: sort(onlyUpstream), onlyOurs: sort(onlyOurs), both: sort(both) };
}

function renderDetailBody(image, body) {
  const detail = state.details.get(image.name);
  if (!detail) return;
  const facts = el("dl", { class: "facts" });
  for (const side of SIDES) {
    const info = detail[side.key];
    const parts = [el("code", { text: info.ref })];
    if (info.digest) parts.push(el("br"), el("code", { text: info.digest }));
    if (info.created) parts.push(el("br"), `built ${shortDate(info.created)}`);
    if (info.error) parts.push(el("br"), unavailable(side.key, info));
    if (side.key === "ours" && !info.error) parts.push(el("br"), el("a", { href: `sboms/${encodeURIComponent(image.name)}.spdx.json`, text: "SBOM (SPDX JSON)" }));
    facts.append(el("div", {}, el("dt", {}, key(side.key), side.label), el("dd", {}, parts)));
  }

  const c = compare(detail);
  const sections = [facts];
  const scope = `${SCANNER_LABEL[state.scanner]}${state.fixableOnly ? ", only findings with a fix" : ""}`;
  if (!c.ours || !c.upstream) {
    sections.push(el("p", { class: "muted", text: "Both images are needed for a comparison; one of them could not be scanned." }));
  } else {
    sections.push(
      el("h4", { text: `Only in upstream (${c.onlyUpstream.length})` }),
      c.onlyUpstream.length ? findingTable(c.onlyUpstream, `Only in upstream's image, ${scope}`, false) : el("p", { class: "muted", text: "None." }),
      el("h4", { text: `Only in ours (${c.onlyOurs.length})` }),
      c.onlyOurs.length ? findingTable(c.onlyOurs, `Only in our image, ${scope}`, false) : el("p", { class: "muted", text: "None." }),
      el("details", { class: "more" },
        el("summary", { text: `In both (${c.both.length})` }),
        c.both.length ? findingTable(c.both, `In both images, ${scope}`, true) : el("p", { class: "muted", text: "None." }),
      ),
    );
  }
  body.replaceChildren(...sections);
}

function renderImages() {
  const container = document.getElementById("images");
  const open = new Set([...container.querySelectorAll("details.image[open]")].map((d) => d.dataset.name));
  container.replaceChildren(...state.latest.images.map((image) => {
    const figures = SIDES.map((side) => {
      const s = scans(image, side.key);
      return `${side.label.toLowerCase()} ${s ? `${fmt.format(s.fixable)} with a fix of ${fmt.format(s.total)}` : "n/a"}`;
    }).join(" · ");
    const body = el("div", { class: "body" }, el("p", { class: "muted", text: "Loading…" }));
    const details = el("details", { class: "image", id: `image-${image.name}` },
      el("summary", {}, el("span", { class: "name", text: image.name }), el("span", { class: "figures", text: `${image.version} · ${figures}` })),
      body,
    );
    details.dataset.name = image.name;
    details.addEventListener("toggle", async () => {
      if (!details.open) return;
      if (!state.details.has(image.name)) {
        try {
          const response = await fetch(`data/images/${encodeURIComponent(image.name)}.json`);
          if (!response.ok) throw new Error(response.statusText);
          state.details.set(image.name, await response.json());
        } catch (error) {
          body.replaceChildren(el("p", { class: "muted", text: `Could not load the findings: ${error.message}` }));
          return;
        }
      }
      renderDetailBody(image, body);
    });
    if (open.has(image.name) || location.hash === `#image-${image.name}`) details.open = true;
    return details;
  }));
}

// --- Wiring ---------------------------------------------------------------------------

function render() {
  renderTiles();
  renderChart();
  renderOverview();
  renderImages();
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
  render();

  const form = document.getElementById("filters");
  form.addEventListener("change", () => {
    state.scanner = form.elements.scanner.value;
    state.fixableOnly = form.elements.fixable.checked;
    render();
  });
  let width = document.getElementById("chart").clientWidth;
  new ResizeObserver(([entry]) => {
    if (Math.abs(entry.contentRect.width - width) < 8) return;
    width = entry.contentRect.width;
    renderChart();
  }).observe(document.getElementById("chart"));
}

main();
