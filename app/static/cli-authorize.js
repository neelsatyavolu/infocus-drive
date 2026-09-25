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
    $("cli-google").href = `/auth/login?next=${encodeURIComponent(location.pathname + location.search)}`;
    show("cli-signin");
    return;
  }
  $("cli-device").textContent = `InFocus CLI on ${request.device.trim() || "an unnamed device"}`;
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
  // Signing in with email/NAS happens in another tab; re-check when we're back.
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && !$("cli-signin").hidden) refresh();
  });
  refresh();
}
