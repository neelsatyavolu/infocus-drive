// One team project on the editing dashboard: sequences and who holds each, footage with
// upload, the team with invites, and storage and cleanup. It follows the project's change
// feed (members) or polls (an admin who isn't a member), so it stays current by itself.

import { $, el } from "./dom.js?v=20261117-dash";
import * as api from "./editing-api.js?v=20261117-dash";
import { uploadFootage } from "./editing-upload.js?v=20261117-dash";
import { ago, avatar, dateText, distinctInitials, notice, plural, showOnly, sizeText } from "./editing-ui.js?v=20261117-dash";
import { formatSpeed } from "./format.js?v=20261117-dash";

const EVENTS = ["lock_changed", "sequence_updated", "sequence_deleted", "shared_updated", "media_changed"];
const POLL_MS = 30_000;
const MAX_FILES_SHOWN = 300;

let view = null; // the open project: { id, ov, boxes, source, timer, stopped }

export function stopDetail() {
  if (!view) return;
  view.stopped = true;
  view.source?.close();
  clearInterval(view.timer);
  clearTimeout(view.debounce);
  view = null;
}

function section(title, extra = []) {
  const body = el("div", { class: "ed-block__body" });
  const node = el("section", { class: "ed-block" }, [
    el("div", { class: "ed-block__head" }, [el("h2", { class: "eyebrow ed-block__title", text: title }), ...extra]),
    body,
  ]);
  return { node, body };
}

function errorLine() {
  return el("p", { class: "ed-error", role: "alert", hidden: true });
}

function showError(line, error) {
  line.textContent = error ? error.message : "";
  line.hidden = !error;
}

async function guarded(button, line, fn) {
  button.disabled = true;
  showError(line, null);
  try {
    await fn();
  } catch (error) {
    showError(line, error);
  } finally {
    button.disabled = false;
  }
}

// Sections ------------------------------------------------------------------------------

function head(ov, link) {
  const tag = ov.role === "admin" ? el("span", { class: "ed-tag", text: "Admin view · read-only" })
    : ov.open_to_all ? el("span", { class: "ed-tag", text: "Open to everyone on the Drive" }) : null;
  const copied = el("span", { class: "ed-dim", "aria-live": "polite" });
  const copy = el("button", { type: "button", class: "btn", text: "Copy name", onclick: async () => {
    try {
      await navigator.clipboard.writeText(ov.name);
      copied.textContent = "Copied";
    } catch {
      copied.textContent = "Select the name and copy it";
    }
  } });
  return el("div", { class: "ed-detail-head" }, [
    link("?", "← Team projects", "ed-back"),
    el("div", { class: "ed-title-row" }, [el("h1", { class: "ed-title", text: ov.name }), tag]),
    ov.role === "admin" ? el("p", { class: "ed-admin-note",
      text: "You're not in this team. You can release locks and keep or recycle the project." }) : null,
    el("p", { class: "ed-sub" }, `Made by ${ov.creator.name} · opened ${ago(ov.last_open)}`),
    ov.can_edit ? el("div", { class: "ed-open" }, [
      el("p", {}, ["To edit, open InFocus Cut, go to ", el("strong", { text: "Team" }), " and pick ",
        el("strong", { text: ov.name }), ". Your Mac downloads the footage for the sequence you open and builds its own proxies."]),
      el("div", { class: "ed-actions" }, [copy, copied]),
    ]) : null,
  ]);
}

function sequences(ov) {
  const line = errorLine();
  const online = new Map(ov.members.map((m) => [m.username, m.online]));
  const rows = ov.sequences.map((seq) => {
    const release = ov.is_admin && seq.holder ? el("button", { type: "button", class: "btn", text: "Release lock",
      onclick: (event) => {
        if (!confirm(`Release the lock on ${seq.name}? ${seq.holder.name} may lose unsaved changes.`)) return;
        guarded(event.currentTarget, line, async () => {
          await api.forceRelease(ov.id, seq.id);
          refresh();
        });
      } }) : null;
    // a lock outlives a closed laptop for a while: say so instead of looking live
    const away = seq.holder && online.get(seq.holder.username) === false;
    const status = !seq.holder ? el("span", { class: "ed-dim", text: "Free to edit" })
      : away ? el("span", { class: "ed-dim", text: `Held by ${seq.holder.name} (offline)` })
        : el("span", { class: "ed-seq__who" }, [el("span", { class: "ed-live", "aria-hidden": "true" }), `${seq.holder.name} is editing`]);
    return el("li", { class: "ed-seq" }, [el("span", { class: "ed-seq__name", text: seq.name }), status, release]);
  });
  return [rows.length ? el("ul", { class: "ed-list" }, rows) : notice("No sequences yet. Make one in InFocus Cut."), line];
}

function footageList(files, total) {
  if (!files.length) return notice("No footage yet.");
  const shown = files.slice(0, MAX_FILES_SHOWN);
  return el("div", {}, [
    el("ul", { class: "ed-list ed-files" }, shown.map((f) => el("li", { class: "ed-file" }, [
      el("span", { class: "ed-file__name", text: f.path, title: f.path }),
      el("span", { class: "mono ed-file__size", text: sizeText(f.size) }),
      el("span", { class: "ed-dim ed-file__when", text: f.by ? `${f.by} · ${ago(f.mtime)}` : ago(f.mtime),
        title: f.by ? `Added by ${f.by}` : "" }),
    ]))),
    total > shown.length ? notice(`And ${total - shown.length} more.`) : null,
  ]);
}

function memberRow(m, seqNames, letters) {
  const editing = m.editing.map((id) => seqNames.get(id) || `Sequence ${id}`).join(", ");
  const seen = m.last_seen ? `Last seen ${ago(m.last_seen)}` : "Offline";
  const now = editing ? (m.online ? `Editing ${editing}` : `${seen} · still holds ${editing}`)
    : m.online ? "Online now" : m.last_seen ? seen : "Hasn't opened it yet";
  return el("li", { class: "ed-person" }, [
    avatar(m, m.online, letters.get(m.username)),
    el("div", { class: "ed-person__text" }, [el("span", { text: m.name }), el("span", { class: "ed-dim", text: now })]),
  ]);
}

function team(ov) {
  const line = errorLine();
  const letters = distinctInitials([...ov.members, ...ov.invites]);
  const invites = ov.invites.map((i) => el("li", { class: "ed-person" }, [
    avatar(i, false, letters.get(i.username)),
    el("div", { class: "ed-person__text" }, [el("span", { text: i.name }), el("span", { class: "ed-dim", text: "Invited, hasn't joined" })]),
    ov.can_edit ? el("button", { type: "button", class: "btn btn--quiet", text: "Cancel", "aria-label": `Cancel invite for ${i.name}`,
      onclick: (event) => guarded(event.currentTarget, line, async () => {
        await api.cancelInvite(ov.id, i.username);
        refresh();
      }) }) : null,
  ]));
  return [
    el("ul", { class: "ed-list" }, ov.members.map((m) => memberRow(m, new Map(ov.sequences.map((s) => [s.id, s.name])), letters))),
    invites.length ? el("h3", { class: "ed-minor", text: "Invited" }) : null,
    invites.length ? el("ul", { class: "ed-list" }, invites) : null,
    ov.open_to_all ? notice("Anyone on the Drive can open this project, so there's nobody to invite.") : null,
    line,
  ];
}

function inviteForm(ov) {
  const line = errorLine();
  const input = el("input", { class: "field", id: "ed-invite-name", list: "ed-people", autocomplete: "off",
    placeholder: "Type 2+ letters of a name", "aria-describedby": "ed-invite-help" });
  const options = el("datalist", { id: "ed-people" });
  const byLabel = new Map();
  // The Drive only answers name searches (2+ letters, 20 matches), never the whole roster.
  let timer = 0;
  let asked = "";
  input.addEventListener("input", () => {
    clearTimeout(timer);
    const q = input.value.trim();
    if (q.length < 2 || byLabel.has(q.toLowerCase())) return;
    timer = setTimeout(() => {
      asked = q;
      api.people(q).then(({ people }) => {
        if (asked !== q) return;
        options.replaceChildren();
        for (const p of people) {
          const label = p.name === p.username ? p.name : `${p.name} (${p.username})`;
          byLabel.set(label.toLowerCase(), p.username);
          byLabel.set(p.username.toLowerCase(), p.username);
          options.append(el("option", { value: label }));
        }
      }).catch((error) => showError(line, error));
    }, 250);
  });
  const button = el("button", { type: "submit", class: "btn btn--primary", text: "Invite" });
  const form = el("form", { class: "ed-invite-form", onsubmit: (event) => {
    event.preventDefault();
    const user = byLabel.get(input.value.trim().toLowerCase());
    if (!user) {
      showError(line, new Error("Pick someone from the list."));
      return;
    }
    guarded(button, line, async () => {
      await api.invite(ov.id, [user]);
      input.value = "";
      refresh();
    });
  } }, [
    el("label", { class: "ed-minor", for: "ed-invite-name", text: "Invite a teammate" }),
    el("div", { class: "ed-invite-form__row" }, [input, button]),
    el("p", { class: "ed-dim ed-help", id: "ed-invite-help", text: "They'll see the invitation in InFocus Cut and here." }),
    options,
    line,
  ]);
  return form;
}

function storage(ov) {
  const line = errorLine();
  const cleanup = ov.keep ? "Kept: cleanup leaves this project alone."
    : ov.cleanup?.move_after ? `Moves to the Recycle bin after ${dateText(ov.cleanup.move_after)} unless someone opens it.`
      : "Moves to the Recycle bin after 30 days with nobody opening it. Opening it resets the clock.";
  const keep = ov.can_keep ? el("button", { type: "button", class: "btn", text: ov.keep ? "Stop keeping" : "Keep",
    onclick: (event) => guarded(event.currentTarget, line, async () => {
      await api.keep(ov.id, !ov.keep);
      refresh();
    }) }) : null;
  return [
    el("dl", { class: "ed-facts" }, [
      el("dt", { text: "Footage" }), el("dd", { class: "mono", text: `${sizeText(ov.media_bytes)} · ${plural(ov.media_count, "file")}` }),
      el("dt", { text: "Folder" }), el("dd", { class: "ed-path", text: ov.media_folder }),
      el("dt", { text: "Cleanup" }), el("dd", { text: cleanup }),
    ]),
    keep ? el("div", { class: "ed-actions" }, [keep]) : null,
    line,
  ];
}

// Uploads -------------------------------------------------------------------------------

function uploadRow(file) {
  const bar = el("span", { class: "ed-progress__fill" });
  const meta = el("span", { class: "mono ed-dim", text: "Waiting" });
  const cancel = el("button", { type: "button", class: "btn btn--quiet", text: "Cancel" });
  const row = el("li", { class: "ed-upload" }, [
    el("span", { class: "ed-file__name", text: file.name }),
    meta, cancel,
    el("span", { class: "ed-progress", role: "progressbar", "aria-valuemin": "0", "aria-valuemax": "100", "aria-label": `Uploading ${file.name}` }, bar),
  ]);
  return { row, bar, meta, cancel };
}

function startUploads(files) {
  if (!view) return;
  const { id } = view;
  const list = view.boxes.uploads;
  const key = (f) => `${f.name}|${f.size}|${f.lastModified}`;
  const fresh = Array.from(files).filter((f) => f.size > 0 && !view.active.has(key(f)));
  for (const f of fresh) view.active.add(key(f));
  const chain = fresh.map((file) => {
    const ui = uploadRow(file);
    list.append(ui.row);
    return { file, ui };
  });
  (async () => {
    for (const { file, ui } of chain) {
      const started = performance.now();
      const job = uploadFootage(id, file, ({ loaded, total, resumed }) => {
        const pct = total ? Math.round((loaded / total) * 100) : 100;
        ui.bar.style.width = `${pct}%`;
        ui.bar.parentElement.setAttribute("aria-valuenow", String(pct));
        const speed = formatSpeed(loaded / Math.max(0.5, (performance.now() - started) / 1000));
        ui.meta.textContent = `${pct}%${speed ? ` · ${speed}` : ""}${resumed ? " · resumed" : ""}`;
      });
      ui.cancel.onclick = () => job.cancel();
      try {
        await job.promise;
        ui.meta.textContent = "Done";
        ui.cancel.remove();
        setTimeout(() => ui.row.remove(), 4000);
      } catch (error) {
        ui.meta.textContent = error.code === "cancelled" ? "Cancelled. Add it again to resume." : `${error.message}. Add it again to resume.`;
        ui.cancel.remove();
      }
      if (view?.id === id) {
        view.active.delete(key(file));
        refresh();
      }
    }
  })();
}

function footage(ov) {
  const picker = el("input", { type: "file", multiple: true, hidden: true, accept: "video/*,audio/*,image/*,.mxf,.braw,.r3d",
    onchange: () => {
      startUploads(picker.files);
      picker.value = "";
    } });
  const add = ov.can_edit ? el("button", { type: "button", class: "btn btn--primary", text: "Add footage", onclick: () => picker.click() }) : null;
  const summary = el("span", { class: "mono ed-dim" });
  const s = section("Footage", [summary, add, picker]);
  const list = el("div");
  const uploads = el("ul", { class: "ed-list ed-uploads", "aria-label": "Uploads" });
  if (ov.can_edit) {
    s.body.append(el("p", { class: "ed-dim ed-help" },
      `Drop files here or use Add footage. They go to ${ov.media_folder}, and each teammate's Mac picks them up.`));
    for (const type of ["dragenter", "dragover"]) {
      s.node.addEventListener(type, (event) => {
        if (!event.dataTransfer?.types?.includes("Files")) return;
        event.preventDefault();
        s.node.classList.add("is-drop");
      });
    }
    s.node.addEventListener("dragleave", (event) => {
      if (!s.node.contains(event.relatedTarget)) s.node.classList.remove("is-drop");
    });
    s.node.addEventListener("drop", (event) => {
      event.preventDefault();
      s.node.classList.remove("is-drop");
      startUploads(event.dataTransfer.files);
    });
  }
  s.body.append(uploads, list);
  return { node: s.node, summary, list, uploads };
}

// Render --------------------------------------------------------------------------------

async function load(id) {
  const [ov, media] = await Promise.all([api.overview(id), api.media(id)]);
  return { ov, media };
}

function fill({ ov, media }) {
  const b = view.boxes;
  b.sequences.replaceChildren(...sequences(ov).filter(Boolean));
  b.footage.summary.textContent = `${plural(media.count, "file")} · ${sizeText(media.bytes)}`;
  b.footage.list.replaceChildren(footageList(media.files, media.count));
  b.team.replaceChildren(...team(ov).filter(Boolean));
  b.storage.replaceChildren(...storage(ov).filter(Boolean));
  view.ov = ov;
}

async function refresh() {
  if (!view || view.stopped) return;
  const current = view;
  try {
    const data = await load(current.id);
    if (view === current) fill(data);
  } catch {
    /* keep what is shown; the next event or poll tries again */
  }
}

function soon() {
  clearTimeout(view?.debounce);
  if (view) view.debounce = setTimeout(refresh, 300);
}

function follow(ov) {
  view.timer = setInterval(refresh, POLL_MS);
  if (!ov.can_edit || typeof EventSource !== "function") return;
  const source = new EventSource(api.eventsUrl(ov.id));
  for (const name of EVENTS) source.addEventListener(name, soon);
  view.source = source;
}

export async function renderDetail(id, _me, { link }) {
  const data = await load(id);
  const { ov } = data;
  const seq = section("Sequences");
  const people = section("Team");
  const store = section("Storage and cleanup");
  const foot = footage(ov);
  view = { id, ov, stopped: false, active: new Set(), boxes: { sequences: seq.body, team: el("div"), storage: store.body, footage: foot, uploads: foot.uploads } };
  people.body.append(view.boxes.team);
  if (ov.can_edit && !ov.open_to_all) people.body.append(inviteForm(ov));
  $("ed-detail").replaceChildren(
    head(ov, link),
    el("div", { class: "ed-grid" }, [
      el("div", { class: "ed-col" }, [seq.node, foot.node]),
      el("div", { class: "ed-col" }, [people.node, store.node]),
    ]),
  );
  fill(data);
  follow(ov);
  showOnly("ed-detail");
}
