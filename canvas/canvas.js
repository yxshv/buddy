// Buddy's canvas. Swift calls window.buddy.draw({...}) with coordinates in CSS px (screen points,
// origin top-left of this screen) and window.buddy.clear().
(() => {
  const SVG = "http://www.w3.org/2000/svg";
  const ink = document.getElementById("ink");
  const cards = document.getElementById("cards");
  const reduced = matchMedia("(prefers-reduced-motion: reduce)");
  const COLORS = {
    red: "#FF3B30", blue: "#0A84FF", green: "#28CD41", yellow: "#FFCC00", orange: "#FF9500",
    purple: "#AF52DE", pink: "#FF2D55", teal: "#30B0C7",
  };
  const LIGHT_INK = new Set(["yellow"]); // labels on these get dark text

  const W = () => window.innerWidth, H = () => window.innerHeight;
  const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), Math.max(lo, hi));
  const color = (name) => COLORS[(name || "").toLowerCase()] || (/^#[0-9a-f]{3,8}$/i.test(name || "") ? name : COLORS.red);

  // Marks drawn in one reply play one after another, like a hand drawing them.
  let queueEnd = 0;
  const slot = (duration) => {
    const now = performance.now();
    const start = Math.max(now, queueEnd);
    queueEnd = start + duration * 0.75;
    return start - now;
  };

  function el(tag, attrs = {}, parent) {
    const node = document.createElementNS(SVG, tag);
    for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    if (parent) parent.appendChild(node);
    return node;
  }

  function group(c, kind) {
    const g = el("g", { class: `mark ${kind}` }, ink);
    g.style.setProperty("--c", c);
    return g;
  }

  // A stroke with its halo, drawn on over `dur` ms.
  function stroke(g, d, delay, dur) {
    for (const cls of ["halo", "line"]) {
      const p = el("path", { d, class: `${cls} draw`, pathLength: 1 }, g);
      p.style.setProperty("--delay", `${delay}ms`);
      p.style.setProperty("--dur", `${dur}ms`);
    }
  }

  function tag(text, c, colorName, place, delay) {
    if (!text) return;
    const t = document.createElement("div");
    t.className = "tag" + (LIGHT_INK.has((colorName || "").toLowerCase()) ? " light-ink" : "");
    t.textContent = text;
    t.style.setProperty("--c", c);
    t.style.setProperty("--delay", `${delay}ms`);
    cards.appendChild(t);
    const { width, height } = t.getBoundingClientRect();
    const [x, y] = place(width, height);
    t.style.left = `${clamp(x, 8, W() - width - 8)}px`;
    t.style.top = `${clamp(y, 8, H() - height - 8)}px`;
    t.dataset.mark = "1";
  }

  // ---- Marks ----

  function arrow({ from, to, label, color: name }) {
    const c = color(name);
    const [x1, y1] = from, [x2, y2] = to;
    const dx = x2 - x1, dy = y2 - y1, len = Math.hypot(dx, dy) || 1;
    const ux = dx / len, uy = dy / len;
    // A gentle bend reads as drawn on purpose; straight lines look mechanical.
    const bend = Math.min(len * 0.14, 60) * (dx >= 0 ? -1 : 1);
    const cx = (x1 + x2) / 2 - uy * bend, cy = (y1 + y2) / 2 + ux * bend;
    // Direction of the line where it meets the head.
    let tx = x2 - cx, ty = y2 - cy;
    const tl = Math.hypot(tx, ty) || 1; tx /= tl; ty /= tl;
    const headLen = 17, headHalf = 8.5;
    const ex = x2 - tx * headLen * 0.7, ey = y2 - ty * headLen * 0.7;

    const dur = clamp(260 + len * 0.9, 320, 700);
    const delay = slot(dur + 160);
    const g = group(c, "arrow");
    stroke(g, `M${x1},${y1} Q${cx},${cy} ${ex},${ey}`, delay, dur);
    const bx = x2 - tx * headLen, by = y2 - ty * headLen;
    const head = el("path", {
      class: "head pop",
      d: `M${x2},${y2} L${bx - ty * headHalf},${by + tx * headHalf} Q${bx + tx * 3},${by + ty * 3} ${bx + ty * headHalf},${by - tx * headHalf} Z`,
    }, g);
    head.style.setProperty("--delay", `${delay + dur * 0.85}ms`);
    // The label sits at the tail, on the far side from where the arrow points.
    tag(label, c, name, (w, h) => [x1 - ux * (w / 2 + 10) - w / 2, y1 - uy * (h / 2 + 8) - h / 2], delay);
  }

  function ellipsePath(cx, cy, rx, ry) {
    // One clean, slightly tilted loop that closes on itself (an overshoot leaves a notch in the halo).
    const pts = [], start = -2.0, sweep = Math.PI * 2 * 1.002, n = 96, tilt = -0.035;
    for (let i = 0; i <= n; i++) {
      const t = i / n, a = start + sweep * t, grow = 1;
      const px = Math.cos(a) * rx * grow, py = Math.sin(a) * ry * grow;
      pts.push([cx + px * Math.cos(tilt) - py * Math.sin(tilt), cy + px * Math.sin(tilt) + py * Math.cos(tilt)]);
    }
    return "M" + pts.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(" L");
  }

  function circle({ rect, label, color: name }) {
    const c = color(name);
    const [x, y, w, h] = rect;
    const rx = Math.max(w / 2 * 1.18 + 8, 18), ry = Math.max(h / 2 * 1.25 + 8, 16);
    const cx = x + w / 2, cy = y + h / 2;
    const dur = clamp(380 + (rx + ry) * 0.9, 450, 800);
    const delay = slot(dur);
    stroke(group(c, "circle"), ellipsePath(cx, cy, rx, ry), delay, dur);
    tag(label, c, name, (tw, th) => cy - ry - th - 10 > 8 ? [cx - tw / 2, cy - ry - th - 10] : [cx - tw / 2, cy + ry + 10], delay + dur * 0.6);
  }

  function box({ rect, label, color: name }) {
    const c = color(name);
    const pad = 6;
    const [x0, y0, w0, h0] = rect;
    const x = x0 - pad, y = y0 - pad, w = w0 + pad * 2, h = h0 + pad * 2, r = Math.min(10, w / 4, h / 4);
    const d = `M${x + r},${y} H${x + w - r} Q${x + w},${y} ${x + w},${y + r} V${y + h - r} Q${x + w},${y + h} ${x + w - r},${y + h} H${x + r} Q${x},${y + h} ${x},${y + h - r} V${y + r} Q${x},${y} ${x + r},${y} Z`;
    const dur = clamp(350 + (w + h) * 0.5, 420, 800);
    const delay = slot(dur);
    stroke(group(c, "box"), d, delay, dur);
    tag(label, c, name, (tw, th) => y - th - 8 > 8 ? [x, y - th - 8] : [x, y + h + 8], delay + dur * 0.6);
  }

  function underline({ from, to, color: name }) {
    const c = color(name);
    const [x1, y1] = from, [x2, y2] = to;
    const len = Math.abs(x2 - x1);
    const dur = clamp(200 + len * 0.6, 260, 600);
    const delay = slot(dur);
    // A hair of curve, like a marker pulled across.
    stroke(group(c, "underline"), `M${x1},${y1 + 1} Q${(x1 + x2) / 2},${(y1 + y2) / 2 + 3} ${x2},${y2 - 1}`, delay, dur);
  }

  function highlight({ rect, color: name }) {
    const c = color(name || "yellow");
    const [x, y, w, h] = rect;
    const g = group(c, "highlight");
    const r = el("rect", { x: x - 3, y: y - 2, width: w + 6, height: h + 4, rx: 4, class: "wash sweep" }, g);
    r.style.setProperty("--delay", `${slot(420)}ms`);
  }

  const { markdown } = window.BuddyMarkdown;

  function fill(card, text) {
    const blocks = markdown(text);
    let t = 120;
    // Write it out: each block wipes in after the previous one, faster when there's a lot.
    const total = blocks.reduce((n, b) => n + b.replace(/<[^>]+>/g, "").length, 0);
    const speed = clamp(total / 3500, 0.25, 1); // ms per character scale, so long notes finish quickly
    for (const html of blocks) {
      const b = document.createElement("div");
      b.className = "blk";
      b.innerHTML = html;
      const chars = b.textContent.length;
      const dur = clamp((160 + chars * 9) * (1.1 - speed * 0.6), 180, 800);
      b.style.setProperty("--delay", `${t}ms`);
      b.style.setProperty("--dur", `${dur}ms`);
      card.appendChild(b);
      t += dur * 0.7;
    }
    return t;
  }

  function placeCard(card, at, anchorGap) {
    const { width, height } = card.getBoundingClientRect();
    let [x, y] = at;
    x += anchorGap; y += anchorGap;
    if (x + width > W() - 16) x = at[0] - width - anchorGap; // flip left of the point
    if (y + height > H() - 16) y = at[1] - height - anchorGap;
    card.style.left = `${clamp(x, 16, W() - width - 16)}px`;
    card.style.top = `${clamp(y, 16, H() - height - 16)}px`;
  }

  function note({ at, text, color: name }) {
    const c = color(name);
    const card = document.createElement("div");
    card.className = "card note md";
    card.style.setProperty("--c", c);
    card.style.setProperty("--delay", `${slot(300)}ms`);
    card.dataset.mark = "1";
    cards.appendChild(card);
    fill(card, text);
    placeCard(card, at || [W() * 0.5, H() * 0.3], 14);
  }

  // ---- Clearing ----

  function remove(node) {
    node.classList.add("fade-out");
    setTimeout(() => { node.remove(); reportEmpty(); }, 240);
  }

  function clear() {
    queueEnd = 0;
    const marks = [...ink.children, ...cards.querySelectorAll('[data-mark="1"]')];
    for (const node of marks) remove(node);
    reportEmpty();
  }

  function reportEmpty() {
    const empty = ink.children.length === 0 && cards.children.length === 0;
    window.webkit?.messageHandlers?.buddy?.postMessage(empty ? "empty" : "busy");
  }

  const kinds = { arrow, circle, box, underline, highlight, note };

  window.buddy = {
    draw(cmd) {
      try {
        if (cmd.kind === "clear") return clear();
        kinds[cmd.kind]?.(cmd);
        reportEmpty();
      } catch (e) {
        console.error(e);
      }
    },
    clear,
  };
  window.webkit?.messageHandlers?.buddy?.postMessage("ready");
})();
