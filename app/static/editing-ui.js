// Shared bits of the editing dashboard: sections, empty notes, people and numbers.

import { $, el } from "./dom.js?v=20261117-dash";
import { formatModified, formatSize } from "./format.js?v=20261117-dash";

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

/** Unix seconds → "just now" / "3 min ago" / "2 h ago" / "Yesterday" / "Nov 3": fits one line. */
export function shortAgo(seconds) {
  if (!seconds) return "never";
  const delta = Date.now() / 1000 - seconds;
  if (delta < 60) return "just now";
  if (delta < 3600) return `${Math.floor(delta / 60)} min ago`;
  if (delta < 86400) return `${Math.floor(delta / 3600)} h ago`;
  if (delta < 2 * 86400) return "Yesterday";
  return new Date(seconds * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

export function initials(name) {
  const words = String(name || "?").trim().split(/\s+/).filter(Boolean);
  const letters = words.length > 1 ? words[0][0] + words.at(-1)[0] : (words[0] || "?").slice(0, 2);
  return letters.toUpperCase();
}

/** username → initials for a group of people, so two people never share them
 * ("Student Two" and "Student Three" become "SW" and "SH", not "ST" twice). */
export function distinctInitials(people) {
  const list = (people || []).filter(Boolean);
  const tries = [
    (p) => initials(p.name),
    (p) => {
      const words = String(p.name || "?").trim().split(/\s+/).filter(Boolean);
      const last = words.at(-1) || "?";
      return (words[0][0] + (last[1] || last[0])).toUpperCase();
    },
    (p) => (String(p.name || "?")[0] + String(p.username || "?").slice(-1)).toUpperCase(),
  ];
  const out = new Map();
  for (const p of list) {
    const pick = tries.find((t) => list.filter((q) => t(q) === t(p)).length === 1) || tries.at(-1);
    out.set(p.username, pick(p));
  }
  return out;
}

function hue(text) {
  let h = 0;
  for (const ch of String(text || "")) h = (h * 31 + ch.codePointAt(0)) % 360;
  return h;
}

export function avatar(person, online = false, letters = null) {
  const node = el("span", { class: `ed-avatar${online ? " is-online" : ""}`, title: person.name, "aria-hidden": "true" },
    letters || initials(person.name));
  node.style.setProperty("--ed-hue", String(hue(person.username || person.name)));
  return node;
}

export function avatars(people, max = 4) {
  const shown = (people || []).slice(0, max);
  const extra = (people || []).length - shown.length;
  const letters = distinctInitials(people);
  return el("span", { class: "ed-avatars" }, [
    ...shown.map((p) => avatar(p, false, letters.get(p.username))),
    extra > 0 ? el("span", { class: "ed-avatar ed-avatar--more", text: `+${extra}` }) : null,
  ]);
}
