// Editing dashboard: sign-in, the project list (and the admin's "All projects"), and
// routing to one project (?project=<id>, editing-detail.js). Data comes from the team API.

import { $, el } from "./dom.js?v=20261117-dash";
import * as api from "./editing-api.js?v=20261117-dash";
import { renderDetail, stopDetail } from "./editing-detail.js?v=20261117-dash";
import { avatars, fail, initials, nameList, notice, plural, shortAgo, showOnly, sizeText } from "./editing-ui.js?v=20261117-dash";

const PROJECT_ID = /^[0-9a-f]{32}$/;
let me = null;

function applyTheme() {
  let light = false;
  try {
    light = localStorage.getItem("ifd-theme") === "light";
  } catch {
    light = false;
  }
  document.documentElement.classList.toggle("light", light);
}

function params() {
  return new URLSearchParams(location.search);
}

export function go(search) {
  history.pushState(null, "", search || location.pathname);
  route();
}

function link(search, children, cls) {
  return el("a", {
    class: cls,
    href: search,
    onclick: (event) => {
      if (event.metaKey || event.ctrlKey || event.shiftKey) return;
      event.preventDefault();
      go(search);
    },
  }, children);
}

function signIn() {
  const next = location.pathname + location.search.replace(/[?&]error=[^&]*/g, "");
  $("ed-google").href = `/auth/login?next=${encodeURIComponent(next)}`;
  const error = params().get("error");
  $("ed-signin-error").hidden = error !== "not_authorized";
  $("ed-signin-error").textContent = "That Google account isn't on InFocus Drive yet. Ask an adviser to add you.";
  showOnly("ed-signin");
}

// List ---------------------------------------------------------------------------------

function editingNow(project) {
  const holders = Object.values(project.locks || {}).map((lock) => lock.holder);
  if (!holders.length) return el("span", { class: "ed-dim", text: "Nobody editing" });
  const names = new Map((project.members || []).map((m) => [m.username, m.name]));
  const who = [...new Set(holders)].map((h) => names.get(h) || h);
  // one line in the column: a name, or a count with the names on hover
  const text = who.length === 1 ? `${who[0]} editing` : `${who.length} editing`;
  return el("span", { title: `${nameList(who)} editing` }, [el("span", { class: "ed-live", "aria-hidden": "true" }), text]);
}

function invitationCard(project) {
  const status = el("p", { class: "ed-error", hidden: true });
  const act = (fn, after) => async (event) => {
    event.currentTarget.disabled = true;
    try {
      await fn(project.id);
      after();
    } catch (error) {
      status.textContent = error.message;
      status.hidden = false;
      event.currentTarget.disabled = false;
    }
  };
  return el("li", { class: "ed-invite" }, [
    el("div", { class: "ed-invite__text" }, [
      el("strong", { text: project.name }),
      el("span", { class: "ed-dim", text: `${project.invited_by || "A teammate"} invited you` }),
    ]),
    el("div", { class: "ed-actions" }, [
      el("button", { type: "button", class: "btn btn--primary", text: "Join",
        onclick: act(api.join, () => go(`?project=${project.id}`)) }),
      el("button", { type: "button", class: "btn", text: "Decline", onclick: act(api.decline, route) }),
    ]),
    status,
  ]);
}

function projectRow(project) {
  const others = project.role === "admin" ? el("span", { class: "ed-tag", text: "Not a member" }) : null;
  return el("li", { class: "ed-row" }, [
    el("div", { class: "ed-row__name" }, [
      link(`?project=${project.id}`, project.name, "ed-row__link"),
      others,
    ]),
    el("div", { class: "ed-row__people" }, [avatars(project.members), el("span", { class: "ed-dim",
      text: plural(project.members.length, "member") })]),
    el("div", { class: "ed-row__footage" }, [
      el("span", { class: "mono", text: sizeText(project.media_bytes) }),
      el("span", { class: "ed-dim", text: plural(project.media_count, "file") }),
    ]),
    el("div", { class: "ed-row__now" }, editingNow(project)),
    el("div", { class: "ed-row__seen ed-dim", text: project.last_open ? `Opened ${shortAgo(project.last_open)}` : "" }),
  ]);
}

function listHeader() {
  const cells = ["Project", "Team", "Footage", "Right now", "Last opened"];
  return el("li", { class: "ed-row ed-row--head", "aria-hidden": "true" },
    cells.map((text, i) => el("span", { class: `eyebrow${i === 4 ? " ed-row__seen" : ""}`, text })));
}

function filter(all) {
  const option = (label, value) => el("button", {
    type: "button",
    class: `ed-seg__btn${all === value ? " is-active" : ""}`,
    "aria-pressed": String(all === value),
    text: label,
    onclick: () => go(value ? "?all=1" : "?"),
  });
  return el("div", { class: "ed-seg", role: "group", "aria-label": "Which projects" },
    [option("My projects", false), option("All projects", true)]);
}

async function renderList() {
  const all = Boolean(me.is_admin) && params().get("all") === "1";
  const list = await api.projects(all);
  const invited = list.filter((p) => p.role === "invited");
  const rest = list.filter((p) => p.role !== "invited").sort((a, b) => (b.last_open || 0) - (a.last_open || 0));
  const root = $("ed-list");
  root.replaceChildren(...[
    el("div", { class: "ed-head" }, [
      el("div", {}, [
        el("h1", { class: "ed-title", text: "Team projects" }),
        el("p", { class: "ed-sub", text: all
          ? "Every team project on the Drive. Projects you're not in are read-only."
          : "Projects you edit with your team in InFocus Cut." }),
      ]),
      me.is_admin ? filter(all) : null,
    ]),
    invited.length ? el("section", { class: "ed-block", "aria-label": "Invitations" }, [
      el("h2", { class: "eyebrow ed-block__title", text: "Invitations" }),
      rest.length ? null : el("p", { class: "ed-invites-sub", text: "Join one to start editing with your team." }),
      el("ul", { class: "ed-invites" }, invited.map(invitationCard)),
    ]) : null,
    rest.length
      ? el("ul", { class: "ed-rows", "aria-label": "Projects" }, [listHeader(), ...rest.map(projectRow)])
      : invited.length ? null
        : notice("No team projects yet. In InFocus Cut, open Team and choose New project, or ask a teammate to invite you."),
  ].filter(Boolean));
  showOnly("ed-list");
}

// Boot ---------------------------------------------------------------------------------

async function route() {
  stopDetail();
  if (!me) return;
  const id = params().get("project") || "";
  try {
    if (id && PROJECT_ID.test(id)) await renderDetail(id, me, { go, link });
    else await renderList();
  } catch (error) {
    if (error.status === 401) {
      me = null;
      $("ed-me").hidden = true;
      signIn();
      return;
    }
    fail(error.status === 404 ? "Project not found" : "Something went wrong", error.message);
  }
  window.scrollTo(0, 0);
}

async function boot() {
  applyTheme();
  try {
    me = await api.me();
  } catch (error) {
    fail("Can't reach InFocus Drive", error.message);
    return;
  }
  if (!me.authenticated) {
    me = null;
    signIn();
    return;
  }
  $("ed-me-name").textContent = me.name || me.nas_username || "";
  $("ed-me-avatar").textContent = initials(me.name || me.nas_username || "");
  $("ed-me-avatar").setAttribute("aria-label", `Signed in as ${me.name || me.nas_username || ""}`);
  $("ed-me-avatar").title = $("ed-me-avatar").getAttribute("aria-label");
  $("ed-me").hidden = false;
  $("ed-signout").addEventListener("click", async () => {
    try {
      await api.signOut();
    } finally {
      location.assign(location.pathname);
    }
  });
  $("ed-home").addEventListener("click", (event) => {
    event.preventDefault();
    go("?");
  });
  window.addEventListener("popstate", route);
  route();
}

boot();
