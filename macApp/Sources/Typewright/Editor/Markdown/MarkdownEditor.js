// Notion-like block editor for Markdown. The host parses the file into blocks of whole lines (`tw_markdown_blocks`);
// each block edits on its own and writes back only its own lines, so untouched parts of the file stay byte for byte.
'use strict';

window.ed = (() => {
  const host = message => (window.webkit?.messageHandlers?.tw ?? window.twHost)?.postMessage(message);
  const root = document.getElementById('doc');
  const TEXT = new Set(['paragraph', 'heading', 'item', 'quote', 'callout']);
  const SOURCE = new Set(['code', 'math', 'solveng', 'mermaid', 'raw']);
  const ALERTS = { note: 'ℹ️', tip: '💡', important: '❗️', warning: '⚠️', caution: '🛑' };
  const PLACEHOLDER = { paragraph: "Type '/' for commands", heading: 'Heading', item: 'List', quote: 'Quote', callout: 'Callout' };

  let blocks = [];
  let tail = '';
  let sent = '';
  let nextId = 1;
  let undoStack = [];
  let redoStack = [];
  let lastSnapshot = 0;
  let pendingFocus = null;
  let notebookCells = null;
  let notebookTimer = null;
  const renders = new Map();

  // MARK: - Model

  // Empty paragraphs are only on screen; the file never gets their blank lines.
  const text = () => blocks.map(b => (b.virtual || (b.kind === 'paragraph' && !b.src) ? '' : b.gap + b.src)).join('') + tail;
  const byId = id => blocks.find(b => b.id === id);
  const blockOf = node => {
    const el = node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
    const wrap = el?.closest('.blk');
    return wrap ? byId(+wrap.dataset.id) : null;
  };
  const isText = b => b && TEXT.has(b.kind);

  /// Sends the new text after each change; `base` lets the host merge edits that crossed this one.
  function flush(reparse = false) {
    const now = text();
    if (now === sent && !reparse) return;
    host({ type: 'change', text: now, base: sent, reparse, canUndo: undoStack.length > 0, canRedo: redoStack.length > 0 });
    sent = now;
  }

  /// Remembers the text before an edit; typing within a second is one undo step.
  function snapshot(force = false) {
    const now = performance.now();
    if (force || now - lastSnapshot > 1000) undoStack.push({ text: sent, focus: saveFocus() });
    if (undoStack.length > 200) undoStack.shift();
    lastSnapshot = force ? 0 : now;
    redoStack = [];
  }

  function changed(b, { structural = false } = {}) {
    snapshot(structural);
    if (b) serialize(b);
    flush();
    scheduleNotebook();
  }

  // MARK: - Loading

  /// Shows `source` split into `list`, keeping the elements of blocks that didn't change (and so the caret in them).
  function load(source, list) {
    let at = 0;
    const fresh = list.map(b => {
      const block = { prefix: '', ...b, gap: source.slice(at, b.start), src: source.slice(b.start, b.end) };
      at = b.end;
      return block;
    });
    tail = source.slice(at);
    const forced = pendingFocus;
    const focus = forced ?? saveFocus();
    pendingFocus = null;
    const key = b => `${b.kind}\u0000${b.src}`;
    const pool = new Map();
    for (const b of blocks) {
      if (!pool.has(key(b))) pool.set(key(b), []);
      pool.get(key(b)).push(b);
    }
    const next = fresh.map(f => {
      const reuse = pool.get(key(f))?.shift();
      if (reuse) {
        reuse.gap = f.gap;
        return reuse;
      }
      build(f);
      return f;
    });
    for (const list of pool.values()) list.forEach(b => b.el.remove());
    next.forEach((b, i) => {
      if (root.children[i] !== b.el) root.insertBefore(b.el, root.children[i] ?? null);
    });
    blocks = next;
    sent = source;
    renumber();
    ensureTrailingBlock();
    if (focus && (forced || !blocks.some(b => b.el.contains(document.activeElement)))) restoreFocus(focus);
    scheduleNotebook();
  }

  /// The page always ends in a text block, so there's somewhere to click and type below code or tables.
  function ensureTrailingBlock() {
    const last = blocks[blocks.length - 1];
    if (last && isText(last) && last.kind === 'paragraph') return;
    const b = create('paragraph', { gap: blocks.length ? '\n\n' : '' });
    insertAfter(last ?? null, b);
    b.src = '';
    b.virtual = true;
  }

  // MARK: - Building

  function create(kind, fields = {}) {
    const b = { kind, src: '', gap: '\n\n', prefix: '', html: '', ...fields };
    build(b);
    return b;
  }

  function insertAfter(after, b) {
    const index = after ? blocks.indexOf(after) + 1 : 0;
    blocks.splice(index, 0, b);
    root.insertBefore(b.el, blocks[index + 1]?.el ?? null);
    fixGaps(b, true);
  }

  function element(tag, cls, attrs = {}) {
    const el = document.createElement(tag);
    if (cls) el.className = cls;
    for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
    return el;
  }

  function build(b) {
    b.id = nextId++;
    const el = element('div', `blk k-${b.kind}`);
    el.dataset.id = b.id;
    b.el = el;
    const gutter = element('div', 'gutter', { contenteditable: 'false' });
    const add = element('button', 'g-add', { title: 'Add a block below', tabindex: '-1' });
    add.textContent = '+';
    const grip = element('button', 'g-grip', { title: 'Drag to move, click for options', tabindex: '-1', draggable: 'true' });
    grip.textContent = '⋮⋮';
    gutter.append(add, grip);
    el.append(gutter);
    if (isText(b)) buildText(b);
    else if (b.kind === 'hr') {
      el.append(element('hr'));
      el.tabIndex = 0;
    } else buildSource(b);
  }

  function buildText(b) {
    const { el } = b;
    if (b.kind === 'item') {
      el.style.setProperty('--depth', b.depth ?? 0);
      const marker = element('span', 'marker', { contenteditable: 'false' });
      if (b.checked !== undefined && b.checked !== null) {
        const box = element('input', 'check', { type: 'checkbox', tabindex: '-1' });
        box.checked = !!b.checked;
        marker.append(box);
        el.classList.toggle('done', !!b.checked);
      }
      el.append(marker);
    }
    if (b.kind === 'callout') {
      const icon = element('span', 'icon', { contenteditable: 'false', title: 'Change the kind' });
      icon.textContent = ALERTS[b.alert] ?? ALERTS.note;
      el.dataset.alert = b.alert ?? 'note';
      el.append(icon);
    }
    const tag = b.kind === 'heading' ? `h${Math.min(Math.max(b.level || 1, 1), 6)}` : 'div';
    const body = element(tag, 't', { contenteditable: 'true', 'data-ph': placeholder(b) });
    body.innerHTML = b.html ?? '';
    b.body = body;
    el.append(body);
  }

  function placeholder(b) {
    if (b.kind === 'heading') return `Heading ${b.level || 1}`;
    if (b.kind === 'item' && b.checked != null) return 'To-do';
    return PLACEHOLDER[b.kind] ?? '';
  }

  /// Code, math, diagrams, calculations and anything the editor can't show as text: a rendered view, and the
  /// source while it's being edited.
  function buildSource(b) {
    const { el } = b;
    const box = element('div', 'box');
    const bar = element('div', 'bar', { contenteditable: 'false' });
    const view = element('div', 'view');
    const src = element('pre', 'src', { contenteditable: 'plaintext-only', spellcheck: 'false' });
    b.view = view;
    b.srcEl = src;
    if (b.kind === 'code') {
      const lang = element('input', 'lang', { placeholder: 'Plain text', spellcheck: 'false' });
      lang.value = b.lang ?? '';
      b.langEl = lang;
      bar.append(lang);
      setSource(b, b.code ?? '');
      box.append(bar, src);
      el.classList.add('editing-always');
      requestRender(b);
    } else if (b.kind === 'solveng') {
      const badge = element('span', 'badge');
      badge.innerHTML = '<b>ƒx</b> Calculation';
      const state = element('span', 'state');
      b.stateEl = state;
      bar.append(badge, state);
      const error = element('div', 'error');
      b.errorEl = error;
      setSource(b, b.code ?? '');
      view.innerHTML = '<div class="pending">Calculating…</div>';
      box.append(bar, src, view, error);
      requestRender(b);
    } else {
      const label = { math: 'Math', mermaid: 'Diagram', raw: 'Markdown' }[b.kind];
      const badge = element('span', 'badge');
      badge.textContent = label;
      bar.append(badge);
      setSource(b, b.kind === 'raw' ? b.src : b.code ?? '');
      if (b.kind === 'raw') {
        if (b.html?.trim()) view.innerHTML = b.html;
        else view.innerHTML = `<pre class="plain">${escapeHTML(b.src)}</pre>`;
        renderDiagrams(view);
      } else if (b.kind === 'mermaid') renderMermaid(b);
      else requestRender(b);
      box.append(bar, view, src);
    }
    el.append(box);
    el.tabIndex = 0;
  }

  function setSource(b, code) {
    b.srcEl.textContent = code;
    endLine(b.srcEl);
  }

  /// A trailing line break only shows with a `<br>` after it, which isn't part of the text.
  function endLine(src) {
    src.querySelectorAll('br.end').forEach(br => br.remove());
    if (!src.textContent || src.textContent.endsWith('\n')) src.append(element('br', 'end'));
  }

  const sourceText = b => b.srcEl.textContent;

  // MARK: - Rendering by the host

  function requestRender(b) {
    const markdown = renderSource(b);
    if (markdown == null) return;
    renders.set(b.id, markdown);
    host({ type: 'render', id: b.id, markdown });
  }

  function renderSource(b) {
    const code = b.srcEl ? sourceText(b) : '';
    switch (b.kind) {
      case 'code': return '```' + (b.langEl?.value.trim().split(/\s/)[0] || 'text') + '\n' + code + '\n```';
      case 'solveng': return '```solveng\n' + code + '\n```';
      case 'math': return '$$\n' + code + '\n$$';
      case 'raw': return code;
      default: return null;
    }
  }

  /// The host's HTML for a block's source; dropped if the source changed since.
  function rendered(id, html) {
    const b = byId(id);
    if (!b || renders.get(id) !== renderSource(b)) return;
    const doc = new DOMParser().parseFromString(html, 'text/html');
    if (b.kind === 'code' || b.kind === 'solveng') {
      const code = doc.querySelector('pre code') ?? doc.querySelector('pre');
      if (code) highlight(b, code.innerHTML);
    } else if (b.kind === 'math') {
      b.view.innerHTML = doc.body.innerHTML.trim() ? doc.body.innerHTML : '<div class="empty">Empty equation</div>';
    } else if (b.kind === 'raw') {
      b.view.innerHTML = doc.body.innerHTML.trim() ? doc.body.innerHTML : `<pre class="plain">${escapeHTML(sourceText(b))}</pre>`;
      renderDiagrams(b.view);
    }
  }

  /// Puts highlighted HTML in a source element without moving its caret.
  function highlight(b, html) {
    const src = b.srcEl;
    const before = sourceText(b);
    const probe = element('pre');
    probe.innerHTML = html;
    // Fenced code always ends in a line break; the block's own may be missing or longer.
    const tailText = lastTextNode(probe);
    if (tailText?.data.endsWith('\n')) tailText.data = tailText.data.slice(0, -1);
    const shown = probe.textContent;
    if (!before.startsWith(shown) || before.slice(shown.length).trim()) return;
    const caret = document.activeElement === src ? caretOffset(src) : null;
    src.replaceChildren(...probe.childNodes);
    if (before.length > shown.length) src.append(before.slice(shown.length));
    endLine(src);
    if (caret != null) setCaret(src, caret);
  }

  function lastTextNode(node) {
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
    let last = null;
    while (walker.nextNode()) last = walker.currentNode;
    return last;
  }

  let mermaid = null;
  function renderDiagrams(scope) {
    const nodes = [...scope.querySelectorAll('pre.mermaid')];
    if (!nodes.length) return;
    mermaid ??= import('https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs').then(m => {
      m.default.initialize({ startOnLoad: false, theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default' });
      return m.default;
    });
    mermaid.then(m => m.run({ nodes })).catch(() => {});
  }

  function renderMermaid(b) {
    b.view.innerHTML = '';
    const pre = element('pre', 'mermaid');
    pre.textContent = sourceText(b);
    b.view.append(pre);
    renderDiagrams(b.view);
  }

  // MARK: - solveng notebook

  /// Every calculation runs in one worksheet, in order, so a cell sees what the cells above it define.
  function scheduleNotebook() {
    const cells = blocks.filter(b => b.kind === 'solveng').map(b => sourceText(b));
    const json = JSON.stringify(cells);
    if (json === notebookCells) return;
    notebookCells = json;
    clearTimeout(notebookTimer);
    blocks.filter(b => b.kind === 'solveng').forEach(b => b.el.classList.add('stale'));
    if (!cells.length) return;
    notebookTimer = setTimeout(() => host({ type: 'notebook', cells, key: json }), 350);
  }

  /// Results of the cells in order: an SVG each, or null, with the problems found in each.
  function notebook(json, pages, errors) {
    if (json !== notebookCells) return;
    const cells = blocks.filter(b => b.kind === 'solveng');
    cells.forEach((b, i) => {
      b.el.classList.remove('stale');
      const svg = pages?.[i];
      if (svg != null) {
        b.view.innerHTML = svg;
        const s = b.view.querySelector('svg');
        if (s) {
          const width = parseFloat(s.getAttribute('width')), height = parseFloat(s.getAttribute('height'));
          s.removeAttribute('width');
          s.removeAttribute('height');
          // 12pt is the text size at 1em.
          s.style.width = `${width / 12}em`;
          s.style.height = `${height / 12}em`;
        }
      }
      const problems = errors?.filter(e => e.cell === i).map(e => e.message) ?? [];
      b.errorEl.textContent = problems.join('\n');
      b.el.classList.toggle('failed', problems.length > 0);
      b.stateEl.textContent = problems.length ? '' : svg != null ? '' : 'Not calculated';
    });
  }

  // MARK: - Serializing

  const escapeHTML = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

  function escapeText(t, prev, next) {
    let out = '';
    for (let i = 0; i < t.length; i++) {
      const c = t[i], before = i ? t[i - 1] : prev, after = i + 1 < t.length ? t[i + 1] : next;
      if (c === '​') continue;
      if (c === ' ') { out += ' '; continue; }
      if (c === '\\' && /[!-/:-@[-`{-~]/.test(after ?? '')) out += '\\\\';
      else if ('*`['.includes(c)) out += '\\' + c;
      else if (c === '_' && !(/\w/.test(before ?? '') && /\w/.test(after ?? ''))) out += '\\_';
      else if (c === '<' && /[A-Za-z/!?]/.test(after ?? '')) out += '\\<';
      else if (c === '$' && after && !/[\s\d]/.test(after)) out += '\\$';
      else if (c === '~' && (before === '~' || after === '~')) out += '\\~';
      else if (c === '&' && /^#?\w+;/.test(t.slice(i + 1))) out += '\\&';
      else out += c;
    }
    return out;
  }

  /// Inline Markdown for an element's content; soft line breaks stay `\n`.
  function inline(el) {
    let out = '';
    const nodes = [...el.childNodes];
    nodes.forEach((n, i) => {
      if (n.nodeType === Node.TEXT_NODE) {
        const prev = out.slice(-1);
        const next = nodes[i + 1]?.textContent?.[0];
        out += escapeText(n.data, prev, next);
        return;
      }
      if (n.nodeType !== Node.ELEMENT_NODE) return;
      out += element_md(n, i === nodes.length - 1);
    });
    return out;
  }

  function wrap(marker, inner) {
    const m = inner.match(/^(\s*)([\s\S]*?)(\s*)$/);
    return m[2] ? `${m[1]}${marker}${m[2]}${marker}${m[3]}` : inner;
  }

  function element_md(n, last) {
    const tag = n.localName;
    if (n.matches('.tw-math')) {
      const tex = n.dataset.tex ?? '';
      return n.hasAttribute('data-display') ? `$$${tex}$$` : `$${tex}$`;
    }
    if (n.dataset.md != null) return n.dataset.md;
    if (n.hasAttribute('data-escaped-char')) return '\\' + n.textContent;
    switch (tag) {
      case 'strong': case 'b': return wrap('**', inline(n));
      case 'em': case 'i': return wrap('*', inline(n));
      case 'del': case 's': case 'strike': return wrap('~~', inline(n));
      case 'code': {
        const t = n.textContent.replace(/​/g, '');
        if (!t) return '';
        const run = Math.max(0, ...(t.match(/`+/g) ?? []).map(r => r.length)) + 1;
        const fence = '`'.repeat(run);
        const pad = t.startsWith('`') || t.endsWith('`') ? ' ' : '';
        return fence + pad + t + pad + fence;
      }
      case 'a': {
        const href = n.getAttribute('href') ?? '';
        const label = inline(n);
        if (label === href || `mailto:${label}` === href) return label;
        const title = n.getAttribute('title');
        const target = /[\s()]/.test(href) ? `<${href}>` : href;
        return `[${label}](${target}${title ? ` "${title.replace(/"/g, '\\"')}"` : ''})`;
      }
      case 'img': {
        const src = n.getAttribute('src') ?? '';
        const title = n.getAttribute('title');
        return `![${n.getAttribute('alt') ?? ''}](${/[\s()]/.test(src) ? `<${src}>` : src}${title ? ` "${title}"` : ''})`;
      }
      case 'br': return last ? '' : '\\\n';
      case 'span': case 'font': return inline(n);
      case 'div': case 'p': return (n.previousSibling ? '\n' : '') + inline(n);
      case 'input': return '';
      default: {
        const attrs = [...n.attributes].map(a => ` ${a.name}="${a.value.replace(/"/g, '&quot;')}"`).join('');
        return `<${tag}${attrs}>${inline(n)}</${tag}>`;
      }
    }
  }

  /// A line that would start a block of its own is escaped.
  function escapeLineStart(line) {
    if (/^\d+[.)](\s|$)/.test(line)) return line.replace(/^(\d+)([.)])/, '$1\\$2');
    if (/^(#{1,6}(\s|$)|>|[-+*](\s|$)|=+\s*$|-{3,}\s*$|```|~~~|\$\$)/.test(line)) return '\\' + line;
    return line;
  }

  const lastLine = s => s.slice(s.lastIndexOf('\n') + 1);

  function serialize(b) {
    if (b.kind === 'hr') return;
    if (isText(b)) {
      const lines = inline(b.body).replace(/\n+$/, '').split('\n').map(escapeLineStart);
      switch (b.kind) {
        case 'paragraph': {
          const indent = b.prefix.replace(/\S.*$/s, '');
          b.src = lines[0] ? indent + lines.join('\n' + indent) : '';
          break;
        }
        case 'heading': b.src = `${'#'.repeat(b.level || 1)} ${lines.join(' ')}`; break;
        case 'item': {
          b.prefix ||= itemPrefix(b);
          const indent = ' '.repeat(lastLine(b.prefix).length);
          b.src = b.prefix + lines.join('\n' + indent);
          break;
        }
        case 'quote': b.src = '> ' + lines.join('\n> '); break;
        case 'callout': {
          const head = b.prefix && /\[!(\w+)\]/i.exec(b.prefix)?.[1]?.toLowerCase() === b.alert
            ? b.prefix : `> [!${(b.alert ?? 'note').toUpperCase()}]\n> `;
          b.src = head + lines.join('\n> ');
          break;
        }
      }
      b.virtual = false;
      return;
    }
    const code = sourceText(b);
    if (b.kind === 'raw') {
      b.src = code;
      return;
    }
    if (b.kind === 'math' && b.lang !== 'math') {
      b.src = `$$\n${code}\n$$`;
      return;
    }
    const lang = b.kind === 'code' ? b.langEl.value.trim() : b.kind;
    const longest = Math.max(2, ...(code.match(/^\s*`{3,}/gm) ?? []).map(f => f.trim().length));
    const fence = b.fence && b.fence.trim().length > longest ? b.fence : '`'.repeat(longest + 1);
    const open = b.prefix && b.lang === (b.kind === 'code' ? lang : b.lang) && b.prefix.trim().startsWith(fence.trim())
      ? b.prefix : fence.trim() + lang;
    b.src = `${open}\n${code}${code ? '\n' : ''}${fence}`;
  }

  /// A list marker for an item made in the editor, indented under the item before it at one level less.
  function itemPrefix(b) {
    const index = blocks.indexOf(b);
    let indent = '';
    const depth = b.depth ?? 0;
    if (depth > 0) {
      for (let i = index - 1; i >= 0 && blocks[i].kind === 'item'; i--) {
        if ((blocks[i].depth ?? 0) === depth - 1) {
          const marker = lastLine(blocks[i].prefix).match(/^(\s*)([-+*]|\d+[.)])\s/);
          indent = ' '.repeat(marker ? marker[0].length : 2 * depth);
          break;
        }
      }
      if (!indent) indent = '  '.repeat(depth);
    }
    let marker = '-';
    if (b.ordered) {
      let number = 1;
      for (let i = index - 1; i >= 0 && blocks[i].kind === 'item'; i--) {
        const d = blocks[i].depth ?? 0;
        if (d < depth) break;
        if (d === depth) {
          if (blocks[i].ordered) number = (parseInt(lastLine(blocks[i].prefix).trim(), 10) || 0) + 1;
          break;
        }
      }
      marker = `${number}.`;
    } else {
      const sibling = blocks.slice(0, index).reverse().find(x => x.kind === 'item' && (x.depth ?? 0) === depth && !x.ordered);
      marker = sibling ? lastLine(sibling.prefix).trim()[0] ?? '-' : '-';
    }
    const box = b.checked == null ? '' : b.checked ? '[x] ' : '[ ] ';
    return `${indent}${marker} ${box}`;
  }

  /// Blocks the editor made or turned into another kind need a blank line around them, except between items.
  /// A new block gets the gap its neighbours want; an old one only gains a blank line it lacks.
  function fixGaps(b, fresh = false) {
    const index = blocks.indexOf(b);
    const tight = (prev, next) => prev?.kind === 'item' && next?.kind === 'item';
    const blank = gap => /\n[ \t]*\n/.test(gap);
    const fix = (prev, next) => {
      if (!prev || !next) return;
      if (!tight(prev, next) && !blank(next.gap)) next.gap = '\n\n';
      else if (tight(prev, next) && !next.gap.includes('\n')) next.gap = '\n';
    };
    if (fresh) b.gap = index === 0 ? '' : tight(blocks[index - 1], b) ? '\n' : '\n\n';
    fix(blocks[index - 1], b);
    fix(b, blocks[index + 1]);
  }

  // MARK: - Numbers

  function renumber() {
    const counters = [];
    let previous = null;
    for (const b of blocks) {
      if (b.kind !== 'item') {
        counters.length = 0;
        previous = null;
        continue;
      }
      const depth = b.depth ?? 0;
      counters.length = Math.min(counters.length, depth + 1);
      const marker = b.el.querySelector('.marker');
      if (b.checked != null) {
        marker.dataset.n = '';
      } else if (b.ordered) {
        const start = parseInt(lastLine(b.prefix).trim(), 10);
        const n = counters[depth] != null && previous ? counters[depth] + 1 : Number.isFinite(start) ? start : 1;
        counters[depth] = n;
        marker.dataset.n = `${n}.`;
      } else {
        counters[depth] = null;
        marker.dataset.n = ['•', '◦', '▪'][depth % 3];
      }
      previous = b;
    }
  }

  // MARK: - Caret

  /// Characters before a point in an element; atoms count as one.
  function caretOffset(el, node, offset) {
    const sel = getSelection();
    if (node == null) {
      if (!sel.rangeCount) return null;
      const r = sel.getRangeAt(0);
      if (!el.contains(r.endContainer)) return null;
      node = r.endContainer;
      offset = r.endOffset;
    }
    const range = document.createRange();
    range.setStart(el, 0);
    range.setEnd(node, offset);
    return measure(range.cloneContents());
  }

  function measure(frag) {
    let n = 0;
    const walk = node => {
      for (const c of node.childNodes) {
        if (c.nodeType === Node.TEXT_NODE) n += c.data.length;
        else if (c.nodeType === Node.ELEMENT_NODE && (c.getAttribute('contenteditable') === 'false' || c.localName === 'img')) n += 1;
        else if (c.localName === 'br') n += 1;
        else walk(c);
      }
    };
    walk(frag);
    return n;
  }

  function length(el) {
    const range = document.createRange();
    range.selectNodeContents(el);
    return measure(range.cloneContents());
  }

  function pointAt(el, target) {
    let left = target;
    let found = null;
    const walk = node => {
      for (const c of node.childNodes) {
        if (found) return;
        if (c.nodeType === Node.TEXT_NODE) {
          if (left <= c.data.length) { found = [c, left]; return; }
          left -= c.data.length;
        } else if (c.nodeType === Node.ELEMENT_NODE && (c.getAttribute('contenteditable') === 'false' || c.localName === 'img' || c.localName === 'br')) {
          if (left === 0) { found = [node, [...node.childNodes].indexOf(c)]; return; }
          left -= 1;
          if (left === 0) { found = [node, [...node.childNodes].indexOf(c) + 1]; return; }
        } else walk(c);
      }
    };
    walk(el);
    return found ?? [el, el.childNodes.length];
  }

  function setCaret(el, offset, focus = true) {
    if (focus && document.activeElement !== el) el.focus({ preventScroll: true });
    const [node, at] = pointAt(el, Math.max(0, offset ?? length(el)));
    const r = document.createRange();
    r.setStart(node, at);
    r.collapse(true);
    const sel = getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    scrollIntoViewIfNeeded(el);
  }

  function scrollIntoViewIfNeeded(el) {
    const sel = getSelection();
    const rect = sel.rangeCount ? sel.getRangeAt(0).getBoundingClientRect() : el.getBoundingClientRect();
    const r = rect.height ? rect : el.getBoundingClientRect();
    if (r.top < 60) scrollBy(0, r.top - 60);
    else if (r.bottom > innerHeight - 60) scrollBy(0, r.bottom - innerHeight + 60);
  }

  const editable = b => (isText(b) ? b.body : b.srcEl && b.el.classList.contains('editing') ? b.srcEl : null);

  function saveFocus() {
    const b = blocks.find(x => x.el.contains(document.activeElement));
    if (!b) return null;
    const el = editable(b);
    return { index: blocks.indexOf(b), offset: el ? caretOffset(el) : null };
  }

  function restoreFocus(focus) {
    const b = blocks[Math.min(focus.index, blocks.length - 1)];
    if (!b) return;
    if (isText(b)) setCaret(b.body, Math.min(focus.offset ?? 0, length(b.body)));
    else b.el.focus({ preventScroll: true });
  }

  function focusBlock(b, where = 'end') {
    if (!b) return;
    if (isText(b)) setCaret(b.body, where === 'start' ? 0 : typeof where === 'number' ? where : length(b.body));
    else if (b.el.classList.contains('editing-always')) setCaret(b.srcEl, where === 'start' ? 0 : sourceText(b).length);
    else {
      stopEditing();
      b.el.focus({ preventScroll: true });
      scrollIntoViewIfNeeded(b.el);
    }
  }

  // MARK: - Source editing

  let editing = null;

  function startEditing(b, caret = 'end') {
    if (editing === b) return;
    stopEditing();
    editing = b;
    b.el.classList.add('editing');
    b.before = sourceText(b);
    setCaret(b.srcEl, caret === 'start' ? 0 : b.before.length);
  }

  function stopEditing() {
    const b = editing;
    if (!b) return;
    editing = null;
    b.el.classList.remove('editing');
    if (!blocks.includes(b)) return;
    if (b.kind === 'raw' && sourceText(b) !== b.before) {
      snapshot(true);
      serialize(b);
      requestRender(b);
      // A raw edit may make other blocks; the host parses it again.
      flush(true);
    }
  }

  // MARK: - Structure

  function textHTML(b) {
    return b.body?.innerHTML ?? '';
  }

  /// Turns a block into another kind, keeping its text.
  function convert(b, kind, fields = {}) {
    const wasText = isText(b);
    const content = wasText ? textHTML(b) : '';
    const plain = wasText ? b.body.textContent : b.srcEl ? sourceText(b) : '';
    const caret = wasText && b.body.contains(document.activeElement ?? null) ? caretOffset(b.body) : null;
    snapshot(true);
    const fresh = create(kind, { gap: b.gap, ...fields });
    if (isText(fresh)) fresh.body.innerHTML = wasText ? content : escapeHTML(plain);
    else if (fresh.srcEl) setSource(fresh, plain);
    const index = blocks.indexOf(b);
    blocks[index] = fresh;
    b.el.replaceWith(fresh.el);
    fixGaps(fresh);
    serialize(fresh);
    renumber();
    flush();
    scheduleNotebook();
    if (isText(fresh)) setCaret(fresh.body, caret ?? 0);
    else if (fresh.kind === 'code') setCaret(fresh.srcEl, 0);
    else if (fresh.kind === 'hr') focusAfter(fresh);
    else startEditing(fresh, 'end');
    if (fresh.srcEl) requestRender(fresh);
    return fresh;
  }

  function focusAfter(b) {
    let next = blocks[blocks.indexOf(b) + 1];
    if (!next || !isText(next)) {
      next = create('paragraph');
      insertAfter(b, next);
    }
    focusBlock(next, 'start');
  }

  function remove(b, focus = 'previous') {
    const index = blocks.indexOf(b);
    if (index < 0) return;
    snapshot(true);
    blocks.splice(index, 1);
    b.el.remove();
    if (index === 0 && blocks[0]) blocks[0].gap = blocks[0].gap.replace(/^\s*\n/, '');
    renumber();
    flush();
    scheduleNotebook();
    ensureTrailingBlock();
    if (focus === 'previous') focusBlock(blocks[index - 1] ?? blocks[0], index - 1 >= 0 ? 'end' : 'start');
    else if (focus === 'next') focusBlock(blocks[index] ?? blocks[index - 1], 'start');
  }

  function splitAtCaret(b) {
    const sel = getSelection();
    if (!sel.isCollapsed) sel.deleteFromDocument();
    const r = sel.getRangeAt(0);
    const after = document.createRange();
    after.setStart(r.startContainer, r.startOffset);
    after.setEnd(b.body, b.body.childNodes.length);
    const frag = after.extractContents();
    const holder = element('div');
    holder.append(frag);
    return holder.innerHTML;
  }

  function enter(b) {
    const empty = length(b.body) === 0;
    if (b.kind === 'item' && empty) {
      if ((b.depth ?? 0) > 0) return indent(b, -1);
      return convert(b, 'paragraph');
    }
    if ((b.kind === 'quote' || b.kind === 'callout') && empty) return convert(b, 'paragraph');
    const atStart = caretOffset(b.body) === 0 && !empty;
    snapshot(true);
    if (atStart) {
      const kind = b.kind === 'item' ? 'item' : 'paragraph';
      const fresh = create(kind, kind === 'item' ? { depth: b.depth, ordered: b.ordered, checked: b.checked == null ? null : false } : {});
      blocks.splice(blocks.indexOf(b), 0, fresh);
      b.el.before(fresh.el);
      fixGaps(fresh, true);
      serialize(fresh);
      renumber();
      flush();
      return;
    }
    const rest = splitAtCaret(b);
    serialize(b);
    const kind = b.kind === 'item' ? 'item' : 'paragraph';
    const fields = kind === 'item' ? { depth: b.depth, ordered: b.ordered, checked: b.checked == null ? null : false } : {};
    const fresh = create(kind, fields);
    fresh.body.innerHTML = rest;
    insertAfter(b, fresh);
    serialize(fresh);
    renumber();
    flush();
    setCaret(fresh.body, 0);
  }

  function backspaceAtStart(b) {
    if (b.kind === 'item' && (b.depth ?? 0) > 0) return indent(b, -1);
    if (b.kind !== 'paragraph') return convert(b, 'paragraph');
    const index = blocks.indexOf(b);
    const prev = blocks[index - 1];
    if (!prev) return;
    if (isText(prev)) {
      snapshot(true);
      const at = length(prev.body);
      prev.body.append(...b.body.childNodes);
      prev.body.normalize();
      blocks.splice(index, 1);
      b.el.remove();
      serialize(prev);
      renumber();
      flush();
      ensureTrailingBlock();
      setCaret(prev.body, at);
    } else if (length(b.body) === 0) {
      remove(b, 'previous');
    } else focusBlock(prev);
  }

  function deleteAtEnd(b) {
    const next = blocks[blocks.indexOf(b) + 1];
    if (!next) return;
    if (!isText(next)) return focusBlock(next);
    snapshot(true);
    const at = length(b.body);
    b.body.append(...next.body.childNodes);
    b.body.normalize();
    blocks.splice(blocks.indexOf(next), 1);
    next.el.remove();
    serialize(b);
    renumber();
    flush();
    ensureTrailingBlock();
    setCaret(b.body, at);
  }

  function indent(b, delta) {
    if (b.kind !== 'item') return;
    const index = blocks.indexOf(b);
    const prev = blocks[index - 1];
    const max = prev?.kind === 'item' ? (prev.depth ?? 0) + 1 : 0;
    const depth = Math.max(0, Math.min((b.depth ?? 0) + delta, max));
    if (depth === (b.depth ?? 0)) return;
    const caret = caretOffset(b.body);
    snapshot(true);
    b.depth = depth;
    b.prefix = '';
    b.prefix = itemPrefix(b);
    b.el.style.setProperty('--depth', depth);
    serialize(b);
    renumber();
    flush();
    setCaret(b.body, caret ?? 0);
  }

  function toggleCheck(b) {
    snapshot(true);
    b.checked = !b.checked;
    b.prefix = b.prefix.replace(/\[[ xX]\]/, b.checked ? '[x]' : '[ ]');
    b.el.querySelector('.check').checked = b.checked;
    b.el.classList.toggle('done', b.checked);
    serialize(b);
    flush();
  }

  function cycleAlert(b) {
    const kinds = Object.keys(ALERTS);
    b.alert = kinds[(kinds.indexOf(b.alert ?? 'note') + 1) % kinds.length];
    b.el.dataset.alert = b.alert;
    b.el.querySelector('.icon').textContent = ALERTS[b.alert];
    changed(b, { structural: true });
  }

  function duplicate(b) {
    serialize(b);
    snapshot(true);
    const copy = { kind: b.kind, src: b.src, gap: '\n\n', prefix: b.prefix, level: b.level, depth: b.depth, ordered: b.ordered,
                   checked: b.checked, alert: b.alert, lang: b.lang, code: b.srcEl ? sourceText(b) : b.code, fence: b.fence,
                   html: isText(b) ? textHTML(b) : b.view?.innerHTML ?? '' };
    build(copy);
    insertAfter(b, copy);
    renumber();
    flush();
    scheduleNotebook();
  }

  function move(b, target, before) {
    if (b === target) return;
    snapshot(true);
    blocks.splice(blocks.indexOf(b), 1);
    const index = blocks.indexOf(target) + (before ? 0 : 1);
    blocks.splice(index, 0, b);
    root.insertBefore(b.el, blocks[index + 1]?.el ?? null);
    if (b.kind === 'item') {
      const prev = blocks[index - 1];
      b.depth = Math.min(b.depth ?? 0, prev?.kind === 'item' ? (prev.depth ?? 0) + 1 : 0);
      b.el.style.setProperty('--depth', b.depth);
      b.prefix = '';
      b.prefix = itemPrefix(b);
      serialize(b);
    }
    fixGaps(b, true);
    const after = blocks[index + 1];
    if (after) fixGaps(after);
    renumber();
    flush();
    scheduleNotebook();
  }

  // MARK: - Markdown shortcuts

  /// `# `, `- `, `1. `, `[] `, `> `, ```` ``` ```` and `$$ ` at the start of a paragraph turn it into that block.
  function blockShortcut(b) {
    if (b.kind !== 'paragraph' && !(b.kind === 'item' && b.checked == null)) return false;
    const caret = caretOffset(b.body);
    const before = b.body.textContent.replace(/ /g, ' ').slice(0, caret);
    let m;
    const strip = n => {
      const [node, at] = pointAt(b.body, n);
      const r = document.createRange();
      r.setStart(...pointAt(b.body, 0));
      r.setEnd(node, at);
      r.deleteContents();
    };
    if (b.kind === 'item') {
      if (/^\[[ xX]?\] $/.test(before)) {
        strip(before.length);
        const checked = /x/i.test(before);
        convert(b, 'item', { depth: b.depth, checked, prefix: '' });
        return true;
      }
      return false;
    }
    if ((m = /^(#{1,6}) $/.exec(before))) {
      strip(before.length);
      convert(b, 'heading', { level: m[1].length });
    } else if (/^[-*+] $/.test(before)) {
      strip(before.length);
      convert(b, 'item', { depth: 0 });
    } else if ((m = /^(\d+)[.)] $/.exec(before))) {
      strip(before.length);
      convert(b, 'item', { depth: 0, ordered: true, prefix: `${m[1]}. ` });
    } else if ((m = /^(?:[-*+] )?\[([ xX]?)\] $/.exec(before))) {
      strip(before.length);
      convert(b, 'item', { depth: 0, checked: /x/i.test(m[1]) });
    } else if (/^> $/.test(before)) {
      strip(before.length);
      convert(b, 'quote');
    } else if ((m = /^```(\S*) $/.exec(before))) {
      strip(before.length);
      const lang = (m[1] ?? '').trim();
      const kind = lang === 'solveng' ? 'solveng' : lang === 'math' ? 'math' : lang === 'mermaid' ? 'mermaid' : 'code';
      convert(b, kind, { lang });
    } else if (/^\$\$ $/.test(before)) {
      strip(before.length);
      convert(b, 'math');
    } else if (/^(---|\*\*\*|___)$/.test(before) && length(b.body) === 3) {
      strip(3);
      convert(b, 'hr');
    } else return false;
    return true;
  }

  const INLINE = [
    [/(?<all>\*\*(?<t>[^*\s](?:[^*]*[^*\s])?)\*\*)$/, 'strong'],
    [/(?:^|[^*\\])(?<all>\*(?<t>[^*\s](?:[^*]*[^*\s])?)\*)$/, 'em'],
    [/(?:^|[^\w\\])(?<all>_(?<t>[^_\s](?:[^_]*[^_\s])?)_)$/, 'em'],
    [/(?:^|[^`\\])(?<all>`(?<t>[^`]+)`)$/, 'code'],
    [/(?<all>~~(?<t>[^~\s](?:[^~]*[^~\s])?)~~)$/, 'del'],
    [/(?:^|[^$\\])(?<all>\$(?<t>[^$\s](?:[^$]*[^$\s])?)\$)$/, 'math'],
    [/(?<all>\[(?<t>[^\]]+)\]\((?<url>[^)\s]+)\))$/, 'a'],
  ];

  /// `**bold**`, `*em*`, `` `code` ``, `~~struck~~`, `$math$` and `[link](url)` turn into formatting once closed.
  function inlineShortcut(b) {
    const sel = getSelection();
    if (!sel.isCollapsed) return;
    const node = sel.anchorNode;
    if (node?.nodeType !== Node.TEXT_NODE || node.parentElement.closest('code, .tw-math, a')) return;
    const before = node.data.slice(0, sel.anchorOffset);
    for (const [pattern, tag] of INLINE) {
      const m = pattern.exec(before);
      if (!m) continue;
      snapshot(true);
      const r = document.createRange();
      r.setStart(node, before.length - m.groups.all.length);
      r.setEnd(node, before.length);
      r.deleteContents();
      let el;
      if (tag === 'math') el = mathAtom(m.groups.t, false);
      else {
        el = element(tag);
        el.textContent = m.groups.t;
        if (tag === 'a') el.setAttribute('href', m.groups.url);
      }
      r.insertNode(el);
      // Typing goes on after the formatting, not inside it.
      const after = document.createTextNode('​');
      el.after(after);
      const caret = document.createRange();
      caret.setStart(after, 1);
      caret.collapse(true);
      sel.removeAllRanges();
      sel.addRange(caret);
      changed(b);
      return;
    }
  }

  function mathAtom(tex, display) {
    const el = element('span', 'tw-math', { contenteditable: 'false', 'data-tex': tex });
    if (display) el.setAttribute('data-display', '');
    el.textContent = tex;
    const id = `m${nextId++}`;
    el.dataset.render = id;
    renders.set(id, tex);
    host({ type: 'render', id, markdown: `$${tex}$` });
    return el;
  }

  function renderedAtom(id, html) {
    const el = document.querySelector(`[data-render="${id}"]`);
    if (!el) return;
    const doc = new DOMParser().parseFromString(html, 'text/html');
    const math = doc.querySelector('math');
    if (math) el.replaceChildren(document.importNode(math, true));
    delete el.dataset.render;
  }

  // MARK: - Formatting

  function format(command) {
    const b = blockOf(getSelection().anchorNode);
    if (!isText(b)) return;
    if (command === 'code') wrapSelection('code');
    else if (command === 'strike') document.execCommand('strikeThrough');
    else if (command === 'link') {
      const sel = getSelection();
      const anchor = sel.anchorNode?.parentElement?.closest('a');
      if (anchor) anchor.replaceWith(...anchor.childNodes);
      else if (!sel.isCollapsed) {
        const range = sel.getRangeAt(0).cloneRange();
        ask(range.getBoundingClientRect(), '', 'Paste or type a link', url => {
          b.body.focus({ preventScroll: true });
          sel.removeAllRanges();
          sel.addRange(range);
          if (url) document.execCommand('createLink', false, url);
          changed(b);
        });
        return;
      }
    } else document.execCommand(command);
    changed(b);
  }

  function wrapSelection(tag) {
    const sel = getSelection();
    if (!sel.rangeCount || sel.isCollapsed) return;
    const r = sel.getRangeAt(0);
    const existing = r.commonAncestorContainer.parentElement?.closest(tag);
    if (existing) {
      existing.replaceWith(...existing.childNodes);
      return;
    }
    const el = element(tag);
    el.textContent = r.toString();
    r.deleteContents();
    r.insertNode(el);
    sel.selectAllChildren(el);
  }

  // MARK: - Menus

  const COMMANDS = [
    { id: 'paragraph', title: 'Text', hint: 'Plain paragraph', icon: 'T', keys: 'text paragraph plain' },
    { id: 'h1', title: 'Heading 1', hint: 'Big section heading', icon: 'H1', keys: 'heading title h1 #' },
    { id: 'h2', title: 'Heading 2', hint: 'Medium section heading', icon: 'H2', keys: 'heading subtitle h2 ##' },
    { id: 'h3', title: 'Heading 3', hint: 'Small section heading', icon: 'H3', keys: 'heading h3 ###' },
    { id: 'bullet', title: 'Bulleted list', hint: 'A simple list', icon: '•', keys: 'bullet list unordered ul -' },
    { id: 'number', title: 'Numbered list', hint: 'A list with numbers', icon: '1.', keys: 'numbered list ordered ol 1.' },
    { id: 'todo', title: 'To-do list', hint: 'Track tasks with checkboxes', icon: '☑', keys: 'todo task checkbox check []' },
    { id: 'quote', title: 'Quote', hint: 'Capture a quote', icon: '❝', keys: 'quote blockquote >' },
    { id: 'callout', title: 'Callout', hint: 'Make writing stand out', icon: '💡', keys: 'callout note tip warning alert admonition' },
    { id: 'code', title: 'Code', hint: 'Code with highlighting', icon: '</>', keys: 'code snippet fence ```' },
    { id: 'solveng', title: 'Calculation', hint: 'solveng math, calculated live', icon: 'ƒx', keys: 'solveng calculation calculate math units engineering worksheet formula' },
    { id: 'math', title: 'Equation', hint: 'Display math in TeX', icon: '∑', keys: 'math equation latex tex katex $$' },
    { id: 'mermaid', title: 'Diagram', hint: 'Mermaid flowcharts and more', icon: '⎔', keys: 'mermaid diagram chart flowchart graph' },
    { id: 'table', title: 'Table', hint: 'Rows and columns', icon: '▦', keys: 'table grid rows columns' },
    { id: 'divider', title: 'Divider', hint: 'Separate sections', icon: '—', keys: 'divider separator hr rule line ---' },
  ];

  const menu = element('div', 'menu', { hidden: '' });
  document.body.append(menu);
  let menuState = null;

  function openMenu(items, rect, onPick, query = '') {
    menuState = { items, onPick, index: 0, query, rect };
    renderMenu();
  }

  function closeMenu() {
    menuState = null;
    menu.hidden = true;
  }

  function filtered() {
    const q = menuState.query.toLowerCase().trim();
    if (!q) return menuState.items;
    return menuState.items.filter(c => c.title.toLowerCase().includes(q) || c.keys?.includes(q));
  }

  function renderMenu() {
    const items = filtered();
    if (!items.length) return closeMenu();
    menuState.index = Math.min(menuState.index, items.length - 1);
    menu.replaceChildren(...items.map((c, i) => {
      const row = element('div', i === menuState.index ? 'item on' : 'item');
      if (c.divider) row.classList.add('sep');
      row.innerHTML = `<span class="ic">${escapeHTML(c.icon ?? '')}</span><span class="tx"><b>${escapeHTML(c.title)}</b>${c.hint ? `<i>${escapeHTML(c.hint)}</i>` : ''}</span>`;
      row.addEventListener('mousedown', e => {
        e.preventDefault();
        pick(c);
      });
      row.addEventListener('mousemove', () => {
        if (menuState.index !== i) {
          menuState.index = i;
          renderMenu();
        }
      });
      return row;
    }));
    menu.hidden = false;
    const { rect } = menuState;
    const height = menu.offsetHeight;
    const below = rect.bottom + 6 + height < innerHeight;
    menu.style.left = `${Math.min(Math.max(8, rect.left), innerWidth - menu.offsetWidth - 8)}px`;
    menu.style.top = `${(below ? rect.bottom + 6 : Math.max(8, rect.top - height - 6)) + scrollY}px`;
    menu.querySelector('.on')?.scrollIntoView({ block: 'nearest' });
  }

  function pick(c) {
    const state = menuState;
    closeMenu();
    state?.onPick(c);
  }

  function menuKey(e) {
    if (!menuState) return false;
    const items = filtered();
    if (e.key === 'ArrowDown') menuState.index = (menuState.index + 1) % items.length;
    else if (e.key === 'ArrowUp') menuState.index = (menuState.index - 1 + items.length) % items.length;
    else if (e.key === 'Enter' || e.key === 'Tab') {
      pick(items[menuState.index]);
    } else if (e.key === 'Escape') closeMenu();
    else return false;
    e.preventDefault();
    if (menuState) renderMenu();
    return true;
  }

  function caretRect() {
    const sel = getSelection();
    if (!sel.rangeCount) return null;
    const r = sel.getRangeAt(0).cloneRange();
    let rect = r.getClientRects()[0];
    if (!rect) {
      const marker = document.createTextNode('​');
      r.insertNode(marker);
      rect = r.getBoundingClientRect();
      marker.remove();
    }
    return rect;
  }

  let slash = null;

  function openSlash(b) {
    const start = caretOffset(b.body) - 1;
    slash = { block: b, start };
    openMenu(COMMANDS, caretRect() ?? b.body.getBoundingClientRect(), c => runSlash(c));
  }

  function updateSlash() {
    if (!slash || !menuState) return;
    const b = slash.block;
    const caret = caretOffset(b.body);
    const typed = b.body.textContent.slice(slash.start, caret ?? 0);
    if (caret == null || caret <= slash.start || !typed.startsWith('/') || /\s\s|^\/\s/.test(typed) || typed.length > 24) {
      slash = null;
      return closeMenu();
    }
    menuState.query = typed.slice(1);
    menuState.index = 0;
    renderMenu();
  }

  function runSlash(c) {
    const s = slash;
    slash = null;
    if (!s) return;
    const b = s.block;
    const caret = caretOffset(b.body) ?? s.start + 1;
    const r = document.createRange();
    r.setStart(...pointAt(b.body, s.start));
    r.setEnd(...pointAt(b.body, caret));
    r.deleteContents();
    b.body.normalize();
    const empty = length(b.body) === 0 || b.body.textContent.replace(/[​\s]/g, '') === '';
    let target = b;
    if (!empty) {
      serialize(b);
      target = create('paragraph');
      insertAfter(b, target);
    } else b.body.innerHTML = '';
    apply(target, c.id);
  }

  /// Turns a block into what a command makes.
  function apply(b, id) {
    switch (id) {
      case 'paragraph': return convert(b, 'paragraph');
      case 'h1': case 'h2': case 'h3': return convert(b, 'heading', { level: +id[1] });
      case 'bullet': return convert(b, 'item', { depth: b.depth ?? 0 });
      case 'number': return convert(b, 'item', { depth: b.depth ?? 0, ordered: true });
      case 'todo': return convert(b, 'item', { depth: b.depth ?? 0, checked: false });
      case 'quote': return convert(b, 'quote');
      case 'callout': return convert(b, 'callout', { alert: 'tip' });
      case 'code': return convert(b, 'code', { lang: '' });
      case 'math': return convert(b, 'math');
      case 'mermaid': {
        const fresh = convert(b, 'mermaid', { lang: 'mermaid' });
        if (!sourceText(fresh)) {
          setSource(fresh, 'flowchart LR\n  A[Start] --> B[End]');
          serialize(fresh);
          flush();
          renderMermaid(fresh);
          setCaret(fresh.srcEl, sourceText(fresh).length);
        }
        return fresh;
      }
      case 'solveng': {
        const fresh = convert(b, 'solveng', { lang: 'solveng' });
        if (!sourceText(fresh)) {
          setSource(fresh, '');
          setCaret(fresh.srcEl, 0);
        }
        return fresh;
      }
      case 'table': {
        const fresh = convert(b, 'raw');
        setSource(fresh, '| Column | Column |\n| --- | --- |\n|  |  |');
        fresh.before = '';
        stopEditing();
        return fresh;
      }
      case 'divider': return convert(b, 'hr');
      case 'duplicate': return duplicate(b);
      case 'delete': return remove(b, 'previous');
    }
  }

  function blockMenu(b, rect) {
    const turn = COMMANDS.filter(c => c.id !== 'table' && c.id !== 'divider').map(c => ({ ...c, hint: `Turn into ${c.title.toLowerCase()}` }));
    const items = [
      { id: 'duplicate', title: 'Duplicate', icon: '⧉' },
      { id: 'delete', title: 'Delete', icon: '🗑' },
      ...turn.map((c, i) => ({ ...c, divider: i === 0 })),
    ];
    openMenu(items, rect, c => apply(b, c.id));
  }

  // MARK: - Events

  root.addEventListener('keydown', e => {
    if (menuKey(e)) return;
    const b = blockOf(e.target);
    if (!b) return;
    const mod = e.metaKey || e.ctrlKey;
    if (mod && !e.altKey && e.key.toLowerCase() === 'z') {
      e.preventDefault();
      return host({ type: e.shiftKey ? 'redo' : 'undo' });
    }
    if (isText(b) && e.target === b.body) return textKey(e, b, mod);
    if (b.srcEl && e.target === b.srcEl) return sourceKey(e, b, mod);
    if (e.target === b.el) return blockKey(e, b);
  });

  function textKey(e, b, mod) {
    const body = b.body;
    if (mod && !e.shiftKey && !e.altKey) {
      const command = { b: 'bold', i: 'italic', e: 'code', k: 'link', u: 'underline' }[e.key.toLowerCase()];
      if (command) {
        e.preventDefault();
        return format(command === 'underline' ? 'strike' : command);
      }
    }
    if (mod && e.shiftKey && e.key.toLowerCase() === 'x') {
      e.preventDefault();
      return format('strike');
    }
    if (e.key === 'Enter' && !e.isComposing) {
      e.preventDefault();
      if (e.shiftKey) {
        document.execCommand('insertText', false, '\n');
        return;
      }
      return enter(b);
    }
    const sel = getSelection();
    const collapsed = sel.isCollapsed;
    if (e.key === 'Backspace' && collapsed && caretOffset(body) === 0) {
      e.preventDefault();
      return backspaceAtStart(b);
    }
    if (e.key === 'Delete' && collapsed && caretOffset(body) === length(body)) {
      e.preventDefault();
      return deleteAtEnd(b);
    }
    if (e.key === 'Tab') {
      e.preventDefault();
      if (b.kind === 'item') indent(b, e.shiftKey ? -1 : 1);
      else if (!e.shiftKey && b.kind === 'paragraph') {
        const prev = blocks[blocks.indexOf(b) - 1];
        if (prev?.kind === 'item') {
          const fresh = convert(b, 'item', { depth: (prev.depth ?? 0) + 1, ordered: prev.ordered, checked: prev.checked == null ? null : false });
          setCaret(fresh.body, 0);
        }
      }
      return;
    }
    if ((e.key === 'ArrowUp' || e.key === 'ArrowDown') && collapsed && !e.shiftKey && !mod) {
      const rect = caretRect();
      const box = body.getBoundingClientRect();
      const line = parseFloat(getComputedStyle(body).lineHeight) || 24;
      if (rect && (e.key === 'ArrowUp' ? rect.top - box.top < line * 0.8 : box.bottom - rect.bottom < line * 0.8)) {
        const target = blocks[blocks.indexOf(b) + (e.key === 'ArrowUp' ? -1 : 1)];
        if (target) {
          e.preventDefault();
          moveVertically(target, rect.left, e.key === 'ArrowUp');
        }
      }
      return;
    }
    if (e.key === 'ArrowLeft' && collapsed && !e.shiftKey && !mod && !e.altKey && caretOffset(body) === 0) {
      const target = blocks[blocks.indexOf(b) - 1];
      if (target) {
        e.preventDefault();
        focusBlock(target, 'end');
      }
    }
    if (e.key === 'ArrowRight' && collapsed && !e.shiftKey && !mod && !e.altKey && caretOffset(body) === length(body)) {
      const target = blocks[blocks.indexOf(b) + 1];
      if (target) {
        e.preventDefault();
        focusBlock(target, 'start');
      }
    }
  }

  function moveVertically(target, x, up) {
    if (!isText(target)) return focusBlock(target, up ? 'end' : 'start');
    const box = target.body.getBoundingClientRect();
    const y = up ? box.bottom - 4 : box.top + 4;
    const pos = document.caretRangeFromPoint?.(Math.min(Math.max(x, box.left + 1), box.right - 1), y);
    if (pos && target.body.contains(pos.startContainer)) {
      target.body.focus({ preventScroll: true });
      const sel = getSelection();
      sel.removeAllRanges();
      sel.addRange(pos);
      scrollIntoViewIfNeeded(target.body);
    } else focusBlock(target, up ? 'end' : 'start');
  }

  function sourceKey(e, b, mod) {
    const src = b.srcEl;
    if (e.key === 'Escape' || (e.key === 'Enter' && mod)) {
      e.preventDefault();
      if (b.el.classList.contains('editing-always')) return focusAfter(b);
      stopEditing();
      return b.el.focus({ preventScroll: true });
    }
    if (e.key === 'Enter') {
      e.preventDefault();
      // Keeps the line's indentation; Enter on an empty last line leaves code.
      const caret = caretOffset(src);
      const code = sourceText(b);
      const lineStart = code.lastIndexOf('\n', caret - 1) + 1;
      const indentation = code.slice(lineStart, caret).match(/^[ \t]*/)[0];
      if (b.kind === 'code' && caret === code.length && code.endsWith('\n\n')) {
        setSource(b, code.replace(/\n\n$/, ''));
        changed(b);
        return focusAfter(b);
      }
      return insertPlain(b, '\n' + indentation);
    }
    if (e.key === 'Tab') {
      e.preventDefault();
      return insertPlain(b, '  ');
    }
    if (e.key === 'Backspace' && getSelection().isCollapsed && sourceText(b) === '' ) {
      e.preventDefault();
      stopEditing();
      return convert(b, 'paragraph');
    }
    const caret = caretOffset(src);
    const code = sourceText(b);
    if (mod || e.altKey || e.shiftKey) return;
    if ((e.key === 'ArrowUp' || e.key === 'ArrowLeft') && caret === 0 && getSelection().isCollapsed) {
      const target = blocks[blocks.indexOf(b) - 1];
      if (target) {
        e.preventDefault();
        stopEditing();
        focusBlock(target, 'end');
      }
    } else if ((e.key === 'ArrowDown' || e.key === 'ArrowRight') && caret === code.length && getSelection().isCollapsed) {
      e.preventDefault();
      stopEditing();
      focusAfter(b);
    }
  }

  /// WebKit pads a line break typed at the end of preformatted text with another, so source blocks insert their own.
  function insertPlain(b, text) {
    const src = b.srcEl;
    const sel = getSelection();
    if (!sel.rangeCount) return;
    const range = sel.getRangeAt(0);
    range.deleteContents();
    const at = caretOffset(src);
    const code = sourceText(b);
    setSource(b, code.slice(0, at) + text + code.slice(at));
    setCaret(src, at + text.length);
    sourceInput(b);
  }

  function blockKey(e, b) {
    if (e.key === 'Backspace' || e.key === 'Delete') {
      e.preventDefault();
      return remove(b, e.key === 'Backspace' ? 'previous' : 'next');
    }
    if (e.key === 'Enter') {
      e.preventDefault();
      if (b.srcEl) return startEditing(b);
      return focusAfter(b);
    }
    if (e.key === 'ArrowUp' || e.key === 'ArrowLeft') {
      e.preventDefault();
      focusBlock(blocks[blocks.indexOf(b) - 1], 'end');
    } else if (e.key === 'ArrowDown' || e.key === 'ArrowRight') {
      e.preventDefault();
      const next = blocks[blocks.indexOf(b) + 1];
      if (next) focusBlock(next, 'start');
      else focusAfter(b);
    }
  }

  root.addEventListener('beforeinput', e => {
    if (e.inputType === 'historyUndo' || e.inputType === 'historyRedo') {
      e.preventDefault();
      host({ type: e.inputType === 'historyUndo' ? 'undo' : 'redo' });
    }
  });

  function sourceInput(b) {
    endLine(b.srcEl);
    if (b.kind !== 'raw') changed(b);
    clearTimeout(b.renderTimer);
    b.renderTimer = setTimeout(() => (b.kind === 'mermaid' ? renderMermaid(b) : requestRender(b)), b.kind === 'raw' ? 300 : 120);
  }

  root.addEventListener('input', e => {
    const b = blockOf(e.target);
    if (!b) return;
    if (isText(b) && e.target === b.body) {
      if (b.body.innerHTML === '<br>') b.body.innerHTML = '';
      if (e.inputType === 'insertText' && e.data === ' ' && blockShortcut(b)) return;
      if (e.inputType === 'insertText' && e.data === '-' && b.kind === 'paragraph' && b.body.textContent === '---' && blockShortcut(b)) return;
      if (e.inputType === 'insertText' && e.data === '/') {
        const before = b.body.textContent.slice(0, caretOffset(b.body) - 1);
        if (!before || /\s$/.test(before)) openSlash(b);
      } else updateSlash();
      if (e.inputType === 'insertText' && e.data && '*_`~$)'.includes(e.data)) inlineShortcut(b);
      changed(b);
      return;
    }
    if (b.srcEl && e.target === b.srcEl) return sourceInput(b);
    if (b.langEl && e.target === b.langEl) {
      changed(b);
      requestRender(b);
    }
  });

  // ``` and Enter in a paragraph makes a code block.
  root.addEventListener('keydown', e => {
    if (e.key !== 'Enter' || e.shiftKey) return;
    const b = blockOf(e.target);
    if (b?.kind !== 'paragraph' || e.target !== b.body) return;
    const m = /^```(\S*)$/.exec(b.body.textContent.trim());
    if (!m) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    b.body.innerHTML = '';
    const lang = m[1];
    convert(b, lang === 'solveng' ? 'solveng' : lang === 'math' ? 'math' : lang === 'mermaid' ? 'mermaid' : 'code', { lang });
  }, true);

  root.addEventListener('focusout', e => {
    const b = blockOf(e.target);
    if (!b) return;
    if (b === editing && !b.el.contains(e.relatedTarget)) {
      setTimeout(() => {
        if (editing === b && !b.el.contains(document.activeElement)) stopEditing();
      }, 0);
    }
    if (slash && !b.el.contains(e.relatedTarget)) {
      slash = null;
      closeMenu();
    }
  });

  root.addEventListener('mousedown', e => {
    const b = blockOf(e.target);
    if (!b) return;
    if (e.target.closest('.g-add')) {
      e.preventDefault();
      const fresh = create('paragraph');
      insertAfter(b, fresh);
      fresh.body.textContent = '/';
      setCaret(fresh.body, 1);
      changed(fresh);
      openSlash(fresh);
      return;
    }
    if (e.target.closest('.g-grip')) return;
    if (e.target.closest('.check')) {
      e.preventDefault();
      return toggleCheck(b);
    }
    if (e.target.closest('.icon') && b.kind === 'callout') {
      e.preventDefault();
      return cycleAlert(b);
    }
    const math = e.target.closest('.tw-math');
    if (math && isText(b)) {
      e.preventDefault();
      return editMath(b, math);
    }
    if (b.srcEl && !b.el.classList.contains('editing') && !b.el.classList.contains('editing-always') && !e.target.closest('.bar') && !e.target.closest('a')) {
      e.preventDefault();
      startEditing(b);
    }
    if (b.kind === 'hr') {
      e.preventDefault();
      b.el.focus();
    }
  });

  root.addEventListener('click', e => {
    const grip = e.target.closest('.g-grip');
    if (grip) {
      const b = blockOf(grip);
      return blockMenu(b, grip.getBoundingClientRect());
    }
    const link = e.target.closest('a[href]');
    if (link && (e.metaKey || !link.closest('[contenteditable="true"]'))) {
      e.preventDefault();
      host({ type: 'open', href: link.getAttribute('href') });
    }
  });

  // Clicking below the last block continues writing there.
  document.addEventListener('mousedown', e => {
    if (e.target !== document.body && e.target !== document.documentElement && e.target !== root) return;
    const last = blocks[blocks.length - 1];
    if (!last || e.clientY < last.el.getBoundingClientRect().bottom) return;
    e.preventDefault();
    focusBlock(last, 'end');
  });

  function editMath(b, atom) {
    ask(atom.getBoundingClientRect(), atom.dataset.tex ?? '', 'TeX', tex => {
      if (tex == null) return;
      if (!tex.trim()) atom.remove();
      else if (tex.trim() !== atom.dataset.tex) atom.replaceWith(mathAtom(tex.trim(), atom.hasAttribute('data-display')));
      changed(b);
    });
  }

  /// A small field under `rect`; `done` gets its text, or null when cancelled.
  function ask(rect, value, placeholder, done) {
    const input = element('input', 'ask', { spellcheck: 'false', placeholder });
    input.value = value;
    input.style.left = `${rect.left + scrollX}px`;
    input.style.top = `${rect.bottom + scrollY + 6}px`;
    document.body.append(input);
    input.focus();
    let finished = false;
    const finish = result => {
      if (finished) return;
      finished = true;
      input.remove();
      done(result);
    };
    input.addEventListener('keydown', e => {
      e.stopPropagation();
      if (e.key === 'Enter') { e.preventDefault(); finish(input.value); }
      if (e.key === 'Escape') { e.preventDefault(); finish(null); }
    });
    input.addEventListener('blur', () => finish(input.value));
  }

  // MARK: - Dragging blocks

  let dragged = null;
  const indicator = element('div', 'drop', { hidden: '' });
  document.body.append(indicator);

  root.addEventListener('dragstart', e => {
    const grip = e.target.closest?.('.g-grip');
    if (!grip) return;
    dragged = blockOf(grip);
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', dragged.src);
    e.dataTransfer.setDragImage(dragged.el, 20, 12);
    dragged.el.classList.add('dragging');
  });

  const dropTarget = e => {
    const el = document.elementFromPoint(Math.min(innerWidth / 2, e.clientX + 200), e.clientY)?.closest('.blk')
      ?? document.elementFromPoint(e.clientX, e.clientY)?.closest('.blk');
    const b = el ? byId(+el.dataset.id) : null;
    if (!b) return null;
    const rect = b.el.getBoundingClientRect();
    return { b, before: e.clientY < rect.top + rect.height / 2, rect };
  };

  document.addEventListener('dragover', e => {
    if (!dragged) return;
    e.preventDefault();
    const t = dropTarget(e);
    if (!t) return;
    indicator.hidden = false;
    indicator.style.top = `${(t.before ? t.rect.top : t.rect.bottom) + scrollY - 1}px`;
    indicator.style.left = `${t.rect.left + 40}px`;
    indicator.style.width = `${t.rect.width - 40}px`;
  });

  document.addEventListener('drop', e => {
    if (!dragged) return;
    e.preventDefault();
    const t = dropTarget(e);
    if (t && t.b !== dragged) move(dragged, t.b, t.before);
  });

  document.addEventListener('dragend', () => {
    dragged?.el.classList.remove('dragging');
    dragged = null;
    indicator.hidden = true;
  });

  // MARK: - Pasting

  root.addEventListener('paste', e => {
    const b = blockOf(e.target);
    if (!b) return;
    const data = e.clipboardData;
    if ([...data.items].some(i => i.kind === 'file' && i.type.startsWith('image/'))) {
      e.preventDefault();
      return host({ type: 'pasteImage' });
    }
    const plain = data.getData('text/plain');
    if (b.srcEl && e.target === b.srcEl) {
      e.preventDefault();
      return insertPlain(b, plain);
    }
    if (!isText(b) || e.target !== b.body) return;
    e.preventDefault();
    if (!plain.includes('\n')) {
      document.execCommand('insertText', false, plain);
      return;
    }
    insertMarkdown(plain, b);
  });

  /// Pasted lines are Markdown: they go into the file at the caret and the host parses them into blocks.
  function insertMarkdown(markdown, b = blockOf(getSelection().anchorNode)) {
    if (!isText(b)) return;
    snapshot(true);
    const rest = element('div');
    rest.innerHTML = splitAtCaret(b);
    serialize(b);
    const head = b.src;
    let start = 0;
    for (const x of blocks) {
      if (x.virtual) continue;
      start += x.gap.length;
      if (x === b) break;
      start += x.src.length;
    }
    if (b.virtual) {
      b.virtual = false;
      start += b.gap.length;
    }
    b.src = head + markdown + inline(rest);
    pendingFocus = { offsetInText: start + head.length + markdown.length };
    flush(true);
  }

  // MARK: - Host calls

  /// The host's blocks for the text the editor just sent, or for a change made elsewhere.
  function update(source, list) {
    const focusAt = pendingFocus?.offsetInText;
    if (focusAt != null) pendingFocus = null;
    load(source, list);
    if (focusAt != null) {
      let at = 0;
      for (const b of blocks) {
        at += b.gap.length;
        if (focusAt <= at + b.src.length) {
          focusBlock(b, 'end');
          break;
        }
        at += b.src.length;
      }
    }
  }

  function undo(redo = false) {
    const from = redo ? redoStack : undoStack;
    const to = redo ? undoStack : redoStack;
    const step = from.pop();
    if (!step) return false;
    to.push({ text: sent, focus: saveFocus() });
    pendingFocus = step.focus;
    lastSnapshot = 0;
    host({ type: 'change', text: step.text, base: sent, reparse: true, canUndo: undoStack.length > 0, canRedo: redoStack.length > 0 });
    sent = step.text;
    return true;
  }

  /// Empties the page for another file.
  function reset() {
    stopEditing();
    closeMenu();
    blocks.forEach(b => b.el.remove());
    blocks = [];
    tail = '';
    sent = '';
    undoStack = [];
    redoStack = [];
    notebookCells = null;
    clearTimeout(notebookTimer);
    scrollTo(0, 0);
  }

  function setTextSize(px) {
    document.documentElement.style.setProperty('--tw-text', `${px}px`);
  }

  function focus() {
    const b = blocks.find(x => isText(x)) ?? blocks[0];
    if (b && !blocks.some(x => x.el.contains(document.activeElement))) focusBlock(b, 'start');
  }

  return { load: update, rendered: (id, html) => (typeof id === 'string' ? renderedAtom(id, html) : rendered(id, html)),
           notebook, undo, reset, setTextSize, focus, insertMarkdown: markdown => insertMarkdown(markdown), text };
})();
