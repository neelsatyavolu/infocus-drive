// Consent page for `infocus login`. Allow/Deny is a plain form POST; the Drive
// answers with a 303 to the CLI's 127.0.0.1 listener, so the one-time code is
// never readable by page script.

const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);
const request = {
  port: params.get("port") || "",
  state: params.get("state") || "",
  challenge: params.get("challenge") || "",
  device: params.get("device") || "",
};
// `switch=1` (InFocus Cut's Switch Account) signs this browser out first, so the
// person can pick another account instead of being handed the one they had.
const switching = params.get("switch") === "1";
params.delete("switch");
const backHere = location.pathname + (params.toString() ? `?${params}` : "");

function showSignIn() {
  $("cli-google").href = `/auth/login?next=${encodeURIComponent(backHere)}`;
  show("cli-signin");
}

async function useAnotherAccount() {
  try {
    await fetch("/auth/logout", { method: "POST", credentials: "same-origin" });
  } catch {
    fail("Couldn't reach InFocus Drive. Check your connection and try again.");
    return;
  }
  history.replaceState(null, "", backHere);
  showSignIn();
}

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
  for (const section of ["cli-loading", "cli-signin", "cli-consent", "cli-error"]) {
    $(section).hidden = section !== id;
  }
}

function fail(message) {
  $("cli-error-text").textContent = message;
  show("cli-error");
}

function looksValid() {
  const port = Number(request.port);
  return (
    Number.isInteger(port) &&
    port >= 1024 &&
    port <= 65535 &&
    /^[A-Za-z0-9_-]{16,128}$/.test(request.state) &&
    /^[A-Za-z0-9_-]{43}$/.test(request.challenge)
  );
}

/** InFocus Cut signs in as "InFocus Cut" or "InFocus Cut on <Mac name>". */
function isInFocusCut(device) {
  const d = String(device || "").trim();
  return d === "InFocus Cut" || d.startsWith("InFocus Cut on ");
}

/** Same code the terminal prints: first 8 hex digits of SHA-256("infocus-verify:" + state). */
async function confirmationCode(state) {
  const bytes = new TextEncoder().encode(`infocus-verify:${state}`);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  const hex = Array.from(digest.slice(0, 4), (b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
  return `${hex.slice(0, 4)}-${hex.slice(4)}`;
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
    showSignIn();
    return;
  }
  if (switching && !refresh.switched) {
    refresh.switched = true;
    await useAnotherAccount();
    return;
  }
  if (isInFocusCut(request.device)) {
    // InFocus Cut shows no code: say what is being connected in its words, not the terminal's.
    document.title = "Connect InFocus Cut · InFocus Drive";
    $("cli-title").textContent = "Connect InFocus Cut?";
    $("cli-device").textContent = request.device.trim();
    $("cli-code-hint").hidden = true;
    $("cli-code").hidden = true;
    $("cli-note").textContent =
      "InFocus Cut will open and save your team projects and footage on the Drive. Only allow this if you just clicked Sign in with InFocus Drive in InFocus Cut.";
  } else {
    $("cli-device").textContent = `InFocus CLI on ${request.device.trim() || "an unnamed device"}`;
  }
  $("cli-user").textContent = me.nas_username;
  $("cli-code").textContent = await confirmationCode(request.state);
  $("cli-port").value = request.port;
  $("cli-state").value = request.state;
  $("cli-challenge").value = request.challenge;
  $("cli-device-field").value = request.device;
  show("cli-consent");
}

applyTheme();
if (!looksValid()) {
  fail("This link is incomplete or broken. Run infocus login in your terminal to get a fresh one.");
} else if (!window.isSecureContext) {
  fail("Open InFocus Drive over HTTPS to connect a terminal.");
} else {
  $("cli-consent").addEventListener("submit", () => {
    // Prevent double submits; the browser still sends the clicked button's value.
    setTimeout(() => {
      for (const button of $("cli-consent").querySelectorAll("button")) button.disabled = true;
    });
  });
  $("cli-switch").addEventListener("click", useAnotherAccount);
  // Signing in with email/NAS happens in another tab; re-check when we're back.
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && !$("cli-signin").hidden) refresh();
  });
  refresh();
}
