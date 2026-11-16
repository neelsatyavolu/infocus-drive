// Keep page linked from the team-project cleanup email. Keep = POST …/open,
// which resets the project's 30-day cleanup clock.

const $ = (id) => document.getElementById(id);
const projectId = new URLSearchParams(location.search).get("project") || "";
const SECTIONS = ["keep-loading", "keep-signin", "keep-ask", "keep-done", "keep-error"];

function applyTheme() {
  let light = false;
  try {
    light = localStorage.getItem("ifd-theme") === "light";
  } catch {
    light = false;
  }
  document.documentElement.classList.toggle("light", light);
}

function show(id) {
  for (const section of SECTIONS) $(section).hidden = section !== id;
}

function fail(message) {
  $("keep-error-text").textContent = message;
  show("keep-error");
}

async function refresh() {
  let me;
  try {
    const res = await fetch("/api/me", { credentials: "same-origin" });
    me = await res.json();
  } catch {
    fail("Couldn't reach InFocus Drive. Check your connection and try again.");
    return;
  }
  if (!me.authenticated) {
    $("keep-google").href = `/auth/login?next=${encodeURIComponent(location.pathname + location.search)}`;
    show("keep-signin");
    return;
  }
  show("keep-ask");
}

async function keep() {
  $("keep-button").disabled = true;
  let res;
  try {
    res = await fetch(`/api/team/projects/${projectId}/open`, { method: "POST", credentials: "same-origin" });
  } catch {
    $("keep-button").disabled = false;
    fail("Couldn't reach InFocus Drive. Check your connection and try again.");
    return;
  }
  if (res.ok) {
    show("keep-done");
  } else if (res.status === 404) {
    fail("This project isn't on the Drive anymore. Ask an adviser to restore it from the Recycle bin.");
  } else if (res.status === 403) {
    fail("Your account can't open this project. Ask the teammate who made it.");
  } else {
    $("keep-button").disabled = false;
    fail("Something went wrong. Try again in a minute.");
  }
}

applyTheme();
if (!/^[0-9a-f]{32}$/.test(projectId)) {
  fail("This link is incomplete or broken. Open the project in InFocus Cut instead.");
} else {
  $("keep-button").addEventListener("click", keep);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && !$("keep-signin").hidden) refresh();
  });
  refresh();
}
