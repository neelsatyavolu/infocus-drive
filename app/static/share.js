/**
 * Public shared-file page. No Drive chrome, no session.
 */
import { el, icon } from "./dom.js?v=20260926-design";
import { describeKind, displayName, formatSize, previewKind } from "./format.js?v=20260926-design";
import { enhanceMarkdownPreview, isMarkdown } from "./markdown.js?v=20260926-design";
import { createMediaPlayer } from "./player.js?v=20260926-design";

const THEME_KEY = "ifd-theme";
const TEXT_LIMIT_BYTES = 1_500_000;

const ERROR_COPY = {
  invalid: "This link isn’t valid.",
  expired: "This link expired.",
  unavailable: "This file is no longer available.",
};

function tokenFromPath() {
  const raw = location.pathname.replace(/^\/s\//, "").replace(/\/+$/, "");
  try {
    return decodeURIComponent(raw);
  } catch {
    return raw;
  }
}

function applyTheme(theme) {
  const light = theme === "light";
  const root = document.documentElement;
  root.classList.toggle("light", light);
  root.dataset.theme = light ? "light" : "dark";
  root.style.colorScheme = light ? "light" : "dark";
  const scheme = document.getElementById("meta-color-scheme");
  const color = document.getElementById("meta-theme-color");
  if (scheme) scheme.setAttribute("content", light ? "light" : "dark");
  if (color) color.setAttribute("content", light ? "#f4f6f5" : "#0f110f");
  const use = document.getElementById("share-theme-icon");
  if (use) use.setAttribute("href", light ? "#i-moon" : "#i-sun");
  try {
    localStorage.setItem(THEME_KEY, light ? "light" : "dark");
  } catch {
    /* private mode */
  }
}

function storedTheme() {
  try {
    return localStorage.getItem(THEME_KEY) === "light" ? "light" : "dark";
  } catch {
    return "dark";
  }
}

function formatExpiry(iso) {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function fileUrls(token) {
  const base = `/api/s/${encodeURIComponent(token)}`;
  return {
    meta: base,
    inline: `${base}/file?inline=1`,
    download: `${base}/file`,
  };
}

function mount(node) {
  const main = document.getElementById("share-main");
  if (!main) return;
  main.replaceChildren(node);
}

function errorCard(code, extra) {
  const title = ERROR_COPY[code] || ERROR_COPY.invalid;
  const bits = [el("h1", { class: "share__title", text: title })];
  if (code === "expired" && extra?.expires_at) {
    bits.push(el("p", { class: "share__meta", text: `Expired ${formatExpiry(extra.expires_at)}` }));
  } else {
    bits.push(
      el("p", {
        class: "share__meta",
        text: "Ask whoever sent this for a new link.",
      }),
    );
  }
  return el("div", { class: "share__card share__card--error" }, [
    el("div", { class: "share__kind", "aria-hidden": "true" }, [icon("#i-alert", 22)]),
    ...bits,
  ]);
}

function renderPreview(item, inlineUrl, downloadUrl) {
  const kind = previewKind(item) || item.kind;
  const stage = el("div", { class: `share__preview share__preview--${kind || "file"}` });

  if (kind === "image") {
    const img = el("img", {
      class: "share__img",
      src: inlineUrl,
      alt: displayName(item.name),
    });
    img.addEventListener("error", () => {
      stage.replaceChildren(el("p", { class: "share__preview-fail", text: "Preview couldn’t load. Download the file instead." }));
    });
    stage.append(img);
    return stage;
  }

  if (kind === "video") {
    const player = createMediaPlayer("video", inlineUrl, {
      fullscreenTarget: stage,
      sizeBytes: item.size,
      onDownload: () => {
        window.location.href = downloadUrl;
      },
      onError: () => {
        stage.replaceChildren(
          el("p", {
            class: "share__preview-fail",
            text: "This video format can’t play in the browser. Download it instead.",
          }),
        );
      },
    });
    stage.append(player.node);
    void player.start();
    return stage;
  }

  if (kind === "audio") {
    const player = createMediaPlayer("audio", inlineUrl, {
      onError: () => {
        stage.replaceChildren(
          el("p", {
            class: "share__preview-fail",
            text: "This audio format can’t play in the browser. Download it instead.",
          }),
        );
      },
    });
    stage.append(
      el("div", { class: "aplayer" }, [
        el("div", { class: "aplayer__art" }, [icon("#i-audio", 34)]),
        el("div", { class: "aplayer__name", text: displayName(item.name) }),
        el("div", { class: "aplayer__meta", text: `${describeKind(item).label} · ${formatSize(item.size)}` }),
        player.node,
      ]),
    );
    void player.start();
    return stage;
  }

  if (kind === "pdf") {
    stage.append(
      el("iframe", {
        class: "share__pdf",
        src: `${inlineUrl}#toolbar=0&navpanes=0&view=FitH`,
        title: displayName(item.name),
      }),
    );
    return stage;
  }

  if (kind === "text") {
    stage.append(el("div", { class: "share__preview-fail", text: "Loading…" }));
    void (async () => {
      try {
        const res = await fetch(inlineUrl, { credentials: "same-origin", cache: "no-store" });
        if (!res.ok) throw new Error("load failed");
        const blob = await res.blob();
        const slice = blob.size > TEXT_LIMIT_BYTES ? blob.slice(0, TEXT_LIMIT_BYTES) : blob;
        let text = await slice.text();
        if (blob.size > TEXT_LIMIT_BYTES) {
          text += `\n\n… truncated (${formatSize(blob.size)} file; showing first 1.5 MB)`;
        }
        const pre = el("pre", { class: "share__text", text });
        stage.replaceChildren(pre);
        if (isMarkdown(item.name)) {
          stage.classList.add("share__preview--markdown");
          const bar = el("div", { class: "code__bar" });
          stage.append(bar);
          enhanceMarkdownPreview({ container: stage, raw: pre, bar, text });
        }
      } catch {
        stage.replaceChildren(
          el("p", { class: "share__preview-fail", text: "Couldn’t preview this file. Download it instead." }),
        );
      }
    })();
    return stage;
  }

  return null;
}

function fileCard(data, urls) {
  const item = { name: data.name, size: data.size, is_dir: false };
  const kindMeta = describeKind(item);
  const expiry = formatExpiry(data.expires_at);
  const preview = data.previewable ? renderPreview({ ...item, kind: data.kind }, urls.inline, urls.download) : null;

  return el("div", { class: "share__card" }, [
    el("div", { class: "share__head" }, [
      el("div", { class: "share__kind", style: `color:${kindMeta.color}` }, [icon(kindMeta.icon, 22)]),
      el("div", { class: "share__head-text" }, [
        el("h1", { class: "share__title", text: displayName(data.name) }),
        el("p", {
          class: "share__meta",
          text: [kindMeta.label, formatSize(data.size), expiry ? `Expires ${expiry}` : ""]
            .filter(Boolean)
            .join(" · "),
        }),
      ]),
    ]),
    preview,
    el(
      "a",
      { class: "btn btn--primary btn--modal share__download", href: urls.download },
      [icon("#i-download", 16), "Download"],
    ),
  ]);
}

async function boot() {
  applyTheme(storedTheme());
  const themeBtn = document.getElementById("share-theme");
  if (themeBtn) {
    themeBtn.addEventListener("click", () => {
      applyTheme(storedTheme() === "light" ? "dark" : "light");
    });
  }

  const token = tokenFromPath();
  if (!token) {
    mount(errorCard("invalid"));
    return;
  }
  const urls = fileUrls(token);
  try {
    const res = await fetch(urls.meta, { credentials: "same-origin", cache: "no-store" });
    let data = {};
    try {
      data = await res.json();
    } catch {
      data = {};
    }
    if (!res.ok) {
      mount(errorCard(data.error || "invalid", data));
      return;
    }
    document.title = `${displayName(data.name)} · InFocus Drive`;
    mount(fileCard(data, urls));
  } catch {
    mount(errorCard("unavailable"));
  }
}

boot();
