// Runs only on the UGOS origin, after a browser-bound, one-use exchange.
try {
  if (window !== window.top) throw new Error("Open sign-in in its own tab.");
  const d = JSON.parse(document.getElementById("ugos-login-data").textContent);
  if (!d.token || !d.username || d.uid == null || !d.public_key) {
    throw new Error("UGOS did not return a complete login.");
  }
  const pem = atob(d.public_key);
  if (!/BEGIN (RSA )?PUBLIC KEY/.test(pem)) throw new Error("UGOS returned an invalid session key.");
  let config;
  try { config = JSON.parse(localStorage.getItem("proConfig") || "{}"); }
  catch { config = {}; }
  if (!config || typeof config !== "object" || Array.isArray(config)) config = {};
  config.accessInfo = {
    api_token: d.token, token_where: d.auth_type || "url",
    static_token: d.static_token || d.token, is_ugk: d.is_ugk || false,
    third_token: d.third_token,
  };
  config.deviceInfo = {
    sn: d.sn, model: d.model, name: d.nas_name, color: d.color ?? null,
    ip: d.ip ?? location.hostname, protocol: d.protocol ?? "https", port: d.port ?? (location.port || 0),
    expMode: d.edev, clusterId: d.clusterId || "",
    ext: { netInfo: { ipv4: d.ipv4 ?? [], ipv6: d.ipv6 ?? [] }, httpPort: d.http_port ?? 9999, httpsPort: d.https_port ?? 9443 },
  };
  Object.assign(config, {
    isLogin: true, temporaryCode: null, isScanLogin: false,
    isNeedBind: Boolean(d.need_bind), nasSeries: { productSeries: d.product_series, modelSeries: d.model_series },
    originSystemVersion: d.system_version,
  });
  const version = String(d.system_version || "").split(".");
  const widths = version.length === 3 ? [0, 2, 4] : version.length === 4 ? [0, 2, 2, 4] : [];
  const versionValid = widths.length && version.every((part, index) => /^\d+$/.test(part) && (!widths[index] || part.length <= widths[index]));
  config.system_version = d.version_number ?? (versionValid ? Number(version.map((part, index) => part.padStart(widths[index], "0")).join("")) : 0);
  const user = {
    role: d.role, uid: d.uid, username: d.username, model: d.model,
    nas_name: d.nas_name, deviceSn: d.sn, isDomain: d.is_domain ?? false,
    isBootstrapCompleted: d.is_bootstrap_completed,
  };
  const previous = localStorage.getItem("user-id");
  if (previous && previous !== String(d.uid)) localStorage.setItem("user-change", "true");
  localStorage.setItem("user-id", String(d.uid));
  localStorage.setItem("enPublicKey", pem);
  localStorage.setItem("proUserInfo", JSON.stringify(user));
  localStorage.setItem("proConfig", JSON.stringify(config));
  document.getElementById("ugos-login-data").remove();
  location.replace("/desktop/?os=ugospro#/");
} catch {
  document.getElementById("sign-in-status").textContent = "Could not open UGOS. Allow browser storage, then start sign-in again.";
}
