// Small JSON client for the editing dashboard: the team API with the Drive session cookie.

export class ApiError extends Error {
  constructor(message, status, code = "") {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function messageFrom(body, status) {
  if (body && typeof body.message === "string") return body.message;
  if (body && typeof body.detail === "string") return body.detail;
  if (status === 404) return "That project isn't on the Drive, or you're not in it.";
  if (status === 403) return "Your account can't do that.";
  return "Something went wrong. Try again in a minute.";
}

export async function api(path, { method = "GET", json } = {}) {
  const init = { method, credentials: "same-origin", headers: { Accept: "application/json" } };
  if (json !== undefined) {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(json);
  }
  let res;
  try {
    res = await fetch(path, init);
  } catch {
    throw new ApiError("Couldn't reach InFocus Drive. Check your connection.", 0);
  }
  if (res.status === 204) return null;
  let body = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  if (!res.ok) throw new ApiError(messageFrom(body, res.status), res.status, body?.error || "");
  return body;
}

const team = (id, rest = "") => `/api/team/projects/${encodeURIComponent(id)}${rest}`;

export const me = () => api("/api/me");
export const signOut = () => api("/auth/logout", { method: "POST" });
export const projects = (all) => api(`/api/team/projects${all ? "?all=1" : ""}`);
export const overview = (id) => api(team(id, "/overview"));
export const media = (id) => api(team(id, "/media"));
export const people = (q) => api(`/api/team/people?q=${encodeURIComponent(q)}`);
export const invite = (id, users) => api(team(id, "/invites"), { method: "POST", json: { users } });
export const cancelInvite = (id, user) =>
  api(team(id, `/invites/${encodeURIComponent(user)}`), { method: "DELETE" });
export const join = (id) => api(team(id, "/join"), { method: "POST" });
export const decline = (id) => api(team(id, "/decline"), { method: "POST" });
export const keep = (id, value) => api(team(id, "/keep"), { method: "POST", json: { keep: value } });
export const recycle = (id) => api(team(id, "/recycle"), { method: "POST" });
export const forceRelease = (id, seq) => api(team(id, `/sequences/${seq}/lock/force`), { method: "POST" });
export const eventsUrl = (id) => team(id, "/events");
export const uploadInit = (id, body) => api(team(id, "/media/upload/init"), { method: "POST", json: body });
export const uploadComplete = (id, uploadId) =>
  api(team(id, "/media/upload/complete"), { method: "POST", json: { upload_id: uploadId } });
export const uploadStatus = (uploadId) => api(`/api/upload/status?upload_id=${encodeURIComponent(uploadId)}`);
