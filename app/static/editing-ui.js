// Shared bits of the editing dashboard: sections, empty notes, people and numbers.

import { $, el } from "./dom.js?v=20261116-teamproj";
import { formatModified, formatSize } from "./format.js?v=20261116-teamproj";

const SECTIONS = ["ed-loading", "ed-signin", "ed-list", "ed-detail", "ed-fail"];

export function showOnly(id) {
  for (const section of SECTIONS) $(section).hidden = section !== id;
}

export function fail(title, text) {
  $("ed-fail-title").textContent = title;
  $("ed-fail-text").textContent = text;
  showOnly("ed-fail");
}

export function notice(text) {
  return el("p", { class: "ed-note", text });
}

export function plural(n, word) {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

export function sizeText(bytes) {
  return bytes ? formatSize(bytes) : "0 B";
}

/** Unix seconds → "5 minutes ago" / "Yesterday" / "Nov 3, 2026". */
export function ago(seconds) {
  return seconds ? formatModified(new Date(seconds * 1000).toISOString()).replace(/^Just now$/, "just now") : "never";
}

export function dateText(seconds) {
  return new Date(seconds * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

export function nameList(names) {
  if (names.length <= 2) return names.join(" and ");
  return `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}

export function initials(name) {
  const words = String(name || "?").trim().split(/\s+/).filter(Boolean);
  const letters = words.length > 1 ? words[0][0] + words.at(-1)[0] : (words[0] || "?").slice(0, 2);
  return letters.toUpperCase();
}

export function avatar(person, online = false) {
  return el("span", { class: `ed-avatar${online ? " is-online" : ""}`, title: person.name, "aria-hidden": "true" },
    initials(person.name));
}

export function avatars(people, max = 4) {
  const shown = (people || []).slice(0, max);
  const extra = (people || []).length - shown.length;
  return el("span", { class: "ed-avatars" }, [
    ...shown.map((p) => avatar(p)),
    extra > 0 ? el("span", { class: "ed-avatar ed-avatar--more", text: `+${extra}` }) : null,
  ]);
}
