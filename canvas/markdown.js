// Mini Markdown with KaTeX math and highlighted code, shared by the canvas, the chat panel and the chats window.
// BuddyMarkdown.markdown(text) returns an array of HTML blocks.
(() => {
  const escapeHTML = (s) => s.replace(/[&<>"]/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[ch]));

  // ---- Syntax highlighting ----
  // Each language is an ordered list of token rules; identifiers are then sorted into keywords,
  // constants, builtins, types and function names. Classes are styled in text.css (.tk-*).
  const words = (s) => new Set(s.trim().split(/\s+/));
  const R = {
    hash: ["com", /#.*/],
    shHash: ["com", /(?<![^\s;|&])#.*/], // `#` starts a shell comment only at a word boundary
    slash: ["com", /\/\/.*/],
    dash: ["com", /--.*/],
    block: ["com", /\/\*[\s\S]*?(?:\*\/|$)/],
    xmlCom: ["com", /<!--[\s\S]*?(?:-->|$)/],
    dq: ["str", /"(?:\\[\s\S]|[^"\\\n])*"?/],
    sq: ["str", /'(?:\\[\s\S]|[^'\\\n])*'?/],
    bt: ["str", /`(?:\\[\s\S]|[^`\\])*`?/],
    tripleDq: ["str", /"""[\s\S]*?(?:"""|$)/],
    py: ["str", /[rRbBuUfF]{1,2}(?=["'])(?:"""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$)|"(?:\\.|[^"\\\n])*"?|'(?:\\.|[^'\\\n])*'?)|"""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$)/],
    num: ["num", /(?<![\w$])(?:0[xX][\da-fA-F_]+|0[bBoO][0-7_]+|(?:\d[\d_]*(?:\.\d[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?\d+)?)[a-zA-Z]*/],
    hexColor: ["num", /#[\da-fA-F]{3,8}\b/],
    deco: ["meta", /@[\w.]+/],
    shVar: ["lit", /\$(?:\{[^}\n]*\}?|[\w@#?*!$-])/],
    prompt: ["op", /(?<![^\n])\$ (?=\S)/],
    cssProp: ["prop", /-{0,2}[a-zA-Z][\w-]*(?=\s*:(?!:))/],
    atRule: ["kw", /@[\w-]+/],
    jsonKey: ["prop", /"(?:\\.|[^"\\\n])*"(?=\s*:)/],
    yamlKey: ["prop", /[\w.-]+(?=[ \t]*:(?:\s|$))/],
    tag: ["tag", /<\/?[\w:.-]+|\/?>/],
    attr: ["attr", /[\w:.-]+(?=\s*=)/],
    ins: ["ins", /(?<![^\n])\+.*/],
    del: ["del", /(?<![^\n])-.*/],
    hunk: ["meta", /(?<![^\n])@@.*/],
    id: ["id", /[A-Za-z_$][\w$]*/],
    op: ["op", /[+\-*/%=<>!&|^~?]+|=>|->/],
  };

  const cLike = {
    rules: [R.slash, R.block, R.dq, R.sq, R.deco, R.num, R.id, R.op],
    kw: words(`auto break case char const continue default do double else enum extern float for goto if inline int long
      register return short signed sizeof static struct switch typedef union unsigned void volatile while class namespace
      template typename public private protected virtual override new delete try catch throw throws using operator friend
      bool import package interface extends implements final abstract synchronized instanceof var val fun func go chan
      defer select type map range fn let mut impl trait pub use mod crate match loop move ref where async await dyn as in
      is when object companion data sealed lateinit string readonly internal include define ifdef endif pragma`),
    lit: words("true false null nullptr nil NULL this self Self super None"),
    bi: words("printf scanf malloc free std cout cin endl vector println fmt String System Console Vec Option Some Ok Err Box"),
    caps: true,
  };

  const LANGS = {
    python: {
      rules: [R.hash, R.py, R.dq, R.sq, R.deco, R.num, R.id, R.op],
      kw: words(`and as assert async await break class continue def del elif else except finally for from global if import
        in is lambda nonlocal not or pass raise return try while with yield match case`),
      lit: words("True False None self cls"),
      bi: words(`print len range list dict set tuple str int float bool type isinstance enumerate zip map filter sorted sum
        min max abs open super input round any all iter next reversed hasattr getattr setattr object repr format
        Exception ValueError TypeError KeyError IndexError RuntimeError`),
      caps: true,
    },
    js: {
      rules: [R.slash, R.block, R.bt, R.dq, R.sq, R.deco, R.num, R.id, R.op],
      kw: words(`break case catch class const continue debugger default delete do else export extends finally for from
        function if import in instanceof let new of return static switch throw try typeof var void while with yield async
        await as interface type enum implements private public protected readonly declare namespace abstract keyof
        satisfies get set`),
      lit: words("true false null undefined this NaN Infinity super"),
      bi: words(`console window document globalThis Math JSON Object Array String Number Boolean Promise Map Set WeakMap
        Date Error RegExp Symbol fetch require module process setTimeout setInterval clearTimeout parseInt parseFloat`),
      caps: true,
    },
    swift: {
      rules: [R.slash, R.block, R.tripleDq, R.dq, R.deco, R.num, R.id, R.op],
      kw: words(`actor any as associatedtype async await break case catch class continue default defer deinit do else enum
        extension fallthrough fileprivate final for func guard if import in indirect init inout internal is lazy let
        mutating nonisolated open operator override private protocol public repeat rethrows return some static struct
        subscript switch throw throws try typealias var weak where while convenience required unowned get set willSet
        didSet sending consuming borrowing`),
      lit: words("true false nil self Self super"),
      bi: words("print debugPrint fatalError precondition assert min max abs zip stride"),
      caps: true,
    },
    shell: {
      rules: [R.shHash, R.prompt, R.dq, R.sq, R.shVar, R.num, R.id, R.op],
      kw: words(`if then else elif fi for while until do done case esac in function return exit local export source alias
        unset readonly select time`),
      lit: words("true false"),
      bi: words(`echo cd ls cat grep sed awk find mkdir rm cp mv chmod chown sudo git npm npx bun yarn pnpm pip pip3 python
        python3 node brew curl wget make docker kubectl swift swiftc xcodebuild open touch head tail sort uniq wc xargs tee
        printf read set test ssh scp tar zip unzip which env kill ps cargo go uv conda jupyter`),
    },
    json: { rules: [R.jsonKey, R.dq, R.num, R.id, R.op], kw: words(""), lit: words("true false null") },
    yaml: { rules: [R.hash, R.yamlKey, R.dq, R.sq, R.num, R.id], kw: words(""), lit: words("true false null yes no on off ~") },
    css: { rules: [R.block, R.dq, R.sq, R.atRule, R.cssProp, R.hexColor, R.num], kw: words(""), lit: words("") },
    html: { rules: [R.xmlCom, R.tag, R.attr, R.dq, R.sq], kw: words(""), lit: words("") },
    sql: {
      rules: [R.dash, R.block, R.sq, R.dq, R.num, R.id, R.op],
      kw: words(`select from where and or not insert into values update set delete create table drop alter add join left
        right inner outer full cross on as group by order having limit offset distinct union all in is like between case
        when then else end primary key foreign references index view exists asc desc default with returning if begin
        commit rollback transaction`),
      lit: words("null true false"),
      bi: words("count sum avg min max coalesce now lower upper length cast round"),
      ci: true,
    },
    diff: { rules: [R.hunk, R.ins, R.del], kw: words(""), lit: words("") },
    c: cLike,
  };
  const ALIASES = {
    py: "python", python3: "python", ipython: "python", javascript: "js", jsx: "js", ts: "js", tsx: "js",
    typescript: "js", mjs: "js", cjs: "js", sh: "shell", bash: "shell", zsh: "shell", console: "shell",
    terminal: "shell", shellscript: "shell", jsonc: "json", json5: "json", yml: "yaml", scss: "css", less: "css",
    xml: "html", svg: "html", vue: "html", patch: "diff", cpp: "c", "c++": "c", h: "c", hpp: "c", cc: "c",
    java: "c", kotlin: "c", kt: "c", go: "c", golang: "c", rust: "c", rs: "c", cs: "c", csharp: "c", "c#": "c",
    objc: "c", "objective-c": "c", dart: "c", scala: "c", php: "c",
  };

  // A fence with no language: make a modest guess, or leave it plain.
  function guess(code) {
    if (/^\s*[{[][\s\S]*[}\]]\s*$/.test(code)) { try { JSON.parse(code); return "json"; } catch {} }
    if (/^\s*(def |class \w+.*:\s*$|import \w+\s*$|from [\w.]+ import )|print\(/m.test(code)) return "python";
    if (/^\s*(func |import (SwiftUI|Foundation|AppKit|UIKit)\b|guard let |struct \w+: )/m.test(code)) return "swift";
    if (/\b(const|let|function)\b|=>|console\.log/.test(code)) return "js";
    if (/^(\$ |(sudo |git |npm |bun |brew |pip3? |cd |ls |curl |mkdir )\S)/m.test(code)) return "shell";
    if (/^\s*(select|insert|update|create table)\b/im.test(code)) return "sql";
    if (/^\s*<[\w!]/.test(code)) return "html";
    return null;
  }

  const compiled = new Map();
  function compile(lang) {
    if (!compiled.has(lang)) compiled.set(lang, new RegExp(lang.rules.map(([, re]) => `(${re.source})`).join("|"), "g"));
    return compiled.get(lang);
  }

  function highlight(code, name) {
    const key = ALIASES[name] || name || guess(code);
    const lang = LANGS[key];
    if (!lang) return escapeHTML(code);
    const re = compile(lang);
    const call = /[ \t]*\(/y;
    const span = (cls, text) => `<span class="tk-${cls}">${escapeHTML(text)}</span>`;
    let out = "", at = 0, prev = "", m;
    re.lastIndex = 0;
    while ((m = re.exec(code))) {
      if (!m[0]) { re.lastIndex++; continue; }
      out += escapeHTML(code.slice(at, m.index));
      at = re.lastIndex;
      let cls = lang.rules[m.slice(1).findIndex((g) => g !== undefined)][0];
      const text = m[0];
      if (cls === "id") {
        const w = lang.ci ? text.toLowerCase() : text;
        call.lastIndex = at;
        if (lang.kw.has(w)) cls = "kw";
        else if (lang.lit.has(w)) cls = "lit";
        else if (/^(def|func|function|fn|fun)$/.test(prev)) cls = "fn";
        else if (/^(class|struct|enum|protocol|interface|extension|actor|trait|type)$/.test(prev)) cls = "type";
        else if (lang.bi?.has(w)) cls = "bi";
        else if (call.test(code)) cls = "fn";
        else if (lang.caps && /^[A-Z]\w*[a-z]\w*$/.test(text)) cls = "type";
        else cls = null;
        prev = text;
      } else if (cls !== "op") prev = "";
      out += cls ? span(cls, text) : escapeHTML(text);
    }
    return out + escapeHTML(code.slice(at));
  }

  function codeBlock({ lang, code }) {
    // The label sits above the scroller so long lines never run under it.
    const label = lang ? `<div class="code-lang">${escapeHTML(lang)}</div>` : "";
    return `<div class="code">${label}<pre><code>${highlight(code, lang.toLowerCase())}</code></pre></div>`;
  }

  // Fenced blocks come out first, line by line, so nothing else touches their contents.
  // An unclosed fence (a reply cut short) runs to the end.
  function extractFences(src) {
    const fences = [];
    const out = [];
    const lines = src.split("\n");
    for (let i = 0; i < lines.length; i++) {
      const open = /^([ \t]*)(`{3,}|~{3,})[ \t]*([^\s`]*)[^`]*$/.exec(lines[i]);
      if (!open) { out.push(lines[i]); continue; }
      const [, indent, fence, lang] = open;
      const close = new RegExp(`^[ \\t]*${fence[0] === "`" ? "`" : "~"}{${fence.length},}[ \\t]*$`);
      const body = [];
      for (i++; i < lines.length && !close.test(lines[i]); i++) {
        body.push(lines[i].startsWith(indent) ? lines[i].slice(indent.length) : lines[i].trimStart());
      }
      out.push(`\u0002${fences.push({ lang, code: body.join("\n").replace(/\s+$/, "") }) - 1}\u0002`);
    }
    return { s: out.join("\n"), fences };
  }

  // ---- Math ----
  function renderMath(tex, display) {
    try {
      return window.katex.renderToString(tex, { displayMode: display, throwOnError: false, strict: "ignore", output: "html" });
    } catch (e) {
      return `<span class="katex-error">${escapeHTML(tex)}</span>`;
    }
  }

  // Math is pulled out before markdown so `*` and `_` inside formulas survive.
  function extractMath(src) {
    const math = [];
    const keep = (tex, display) => `\u0000${math.push({ tex: tex.trim(), display }) - 1}\u0000`;
    let s = src
      .replace(/\$\$([\s\S]+?)\$\$/g, (_, t) => keep(t, true))
      .replace(/\\\[([\s\S]+?)\\\]/g, (_, t) => keep(t, true))
      .replace(/\\\(([\s\S]+?)\\\)/g, (_, t) => keep(t, false))
      .replace(/(^|[^\\$])\$(?!\s)([^$\n]+?)(?<!\s)\$(?!\d)/g, (_, pre, t) => pre + keep(t, false));
    return { s, math };
  }

  // ---- Blocks ----
  // Returns an array of HTML blocks (each is wiped in separately).
  function markdown(src) {
    const fenced = extractFences(src.replace(/\r/g, "").trim());
    // Inline code is set aside too, so `$` and `*` inside it stay literal.
    const spans = [];
    const withSpans = fenced.s.replace(/`([^`\n]+)`/g, (_, c) => `\u0001${spans.push(c) - 1}\u0001`);
    const { s, math } = extractMath(withSpans);
    const restore = (html) => html.replace(/\u0000(\d+)\u0000/g, (_, i) => renderMath(math[i].tex, math[i].display));
    const inline = (t) => escapeHTML(t)
      .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
      .replace(/==(.+?)==/g, "<mark>$1</mark>")
      .replace(/(^|[^*\w])\*(?!\s)(.+?)(?<!\s)\*(?!\w)/g, "$1<em>$2</em>")
      .replace(/(^|[^\w])_(?!\s)(.+?)(?<!\s)_(?!\w)/g, "$1<em>$2</em>")
      .replace(/\u0001(\d+)\u0001/g, (_, i) => `<code>${escapeHTML(spans[i])}</code>`);
    const blocks = [];
    let para = [], list = null;
    const flushPara = () => { if (para.length) blocks.push(`<p>${para.map(inline).join("<br>")}</p>`); para = []; };
    const flushList = () => {
      if (list) blocks.push(`<${list.tag}${list.start > 1 ? ` start="${list.start}"` : ""}>${list.items.map((i) => `<li>${inline(i)}</li>`).join("")}</${list.tag}>`);
      list = null;
    };
    for (const raw of s.split("\n")) {
      const line = raw.trim();
      let m;
      if (!line) { flushPara(); flushList(); continue; }
      if ((m = /^\u0002(\d+)\u0002$/.exec(line))) {
        // A code block between numbered steps doesn't restart the count (the list picks up its number again).
        flushPara(); flushList();
        blocks.push(codeBlock(fenced.fences[m[1]]));
      } else if ((m = /^\u0000(\d+)\u0000$/.exec(line)) && math[m[1]].display) {
        flushPara(); flushList();
        blocks.push(`<div class="math-block">${line}</div>`);
      } else if ((m = /^(#{1,3})\s+(.*)$/.exec(line))) {
        flushPara(); flushList();
        blocks.push(`<h${m[1].length}>${inline(m[2])}</h${m[1].length}>`);
      } else if (/^(-{3,}|\*{3,})$/.test(line)) {
        flushPara(); flushList();
        blocks.push("<hr>");
      } else if ((m = /^([-*•]|\d+[.)])\s+(.*)$/.exec(line))) {
        flushPara();
        const tag = /\d/.test(m[1]) ? "ol" : "ul";
        // Numbered steps split by an equation keep counting from where they were.
        if (!list || list.tag !== tag) { flushList(); list = { tag, items: [], start: parseInt(m[1], 10) || 1 }; }
        list.items.push(m[2]);
      } else {
        flushList();
        para.push(line);
      }
    }
    flushPara(); flushList();
    return blocks.map(restore);
  }

  window.BuddyMarkdown = { markdown, escapeHTML, highlight };
})();
