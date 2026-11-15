// Result cards, shared by the chat panel (reply.html) and the chats window (chats.html).
// BuddyCards.html(cards) → markup; clicking a card with a url posts {open: url} to the app.
(() => {
  // SF Symbols, rendered to PNG masks at build time (tools/symbols.swift) and tinted in cards.css.
  const kinds = ["note", "calendar", "file", "email", "task", "link"];
  const colors = { note: "#AF52DE", calendar: "#FF3B30", file: "#0A84FF", email: "#30B0C7", task: "#28CD41", link: "#5E5CE6" };
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  function card(c) {
    const kind = kinds.includes(c.kind) ? c.kind : "link";
    const url = c.url ? ` data-url="${esc(c.url)}" title="${esc(c.url)}"` : "";
    return `<button class="rcard" style="--k:${colors[kind]}"${url}>` +
      `<span class="ic"><i style="--sym:url(symbols/${kind}.png)"></i></span>` +
      `<span class="tx"><span class="t">${esc(c.title)}</span>${c.subtitle ? `<span class="s">${esc(c.subtitle)}</span>` : ""}</span>` +
      (c.url ? `<span class="go"><i></i></span>` : "") + `</button>`;
  }

  window.BuddyCards = {
    html: (cards) => (cards && cards.length ? `<div class="rcards">${cards.map(card).join("")}</div>` : ""),
  };

  // One handler for every card on the page.
  addEventListener("click", (e) => {
    const el = e.target.closest?.(".rcard[data-url]");
    if (!el) return;
    e.preventDefault();
    e.stopPropagation();
    window.webkit?.messageHandlers?.buddy?.postMessage({ open: el.dataset.url });
  }, true);
})();
