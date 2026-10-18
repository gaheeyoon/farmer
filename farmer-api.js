/* Only a publishable/anon key belongs in farmer-config.js. Never add secret/service_role keys. */
(() => {
  "use strict";
  const config = window.FARMER_BACKEND || {};
  const sessionLifetime = 14 * 24 * 60 * 60 * 1000;
  const storageKey = `farmer-admin-session:${config.url}:v1`;
  let session = null,
    refreshing = null,
    generation = 0,
    storageAvailable = true;
  const ready = () =>
    config.enabled === true &&
    /^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(config.url || "") &&
    !!config.publishableKey;
  async function request(path, body, token = null, method = "POST") {
    if (!ready()) throw new Error("주문 시스템 연결 설정이 필요합니다.");
    const controller = new AbortController(),
      timer = setTimeout(() => controller.abort(), 20000);
    try {
      const headers = {
        apikey: config.publishableKey,
        "Content-Type": "application/json",
      };
      if (token) headers.Authorization = `Bearer ${token}`;
      const response = await fetch(config.url + path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller.signal,
        cache: "no-store",
      });
      const result = await response.json().catch(() => null);
      if (!response.ok) {
        const error = new Error(
          result?.message ||
            result?.msg ||
            result?.error_description ||
            "요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.",
        );
        error.status = response.status;
        error.code = result?.code || result?.error_code;
        error.uncertain = response.status >= 500;
        throw error;
      }
      return result;
    } catch (error) {
      if (error.name === "AbortError" || error instanceof TypeError)
        throw Object.assign(
          new Error("연결이 끊겨 처리 결과를 확인하지 못했습니다."),
          { uncertain: true },
        );
      throw error;
    } finally {
      clearTimeout(timer);
    }
  }
  const loginRequired = () => Object.assign(new Error("로그인 유지 기간이 끝났습니다. 다시 로그인해 주세요."), { authRequired: true });
  function readStored() {
    if (!storageAvailable) return undefined;
    try {
      const raw = localStorage.getItem(storageKey);
      if (!raw) return null;
      let value;
      try { value = JSON.parse(raw); } catch { return null; }
      return value && typeof value.id === "string" &&
        typeof value.access_token === "string" && value.access_token &&
        typeof value.refresh_token === "string" && value.refresh_token &&
        Number.isFinite(value.expires_at) && Number.isFinite(value.deadline)
        ? value : null;
    } catch {
      storageAvailable = false;
      return undefined;
    }
  }
  function forgetSession(removeStored = true) {
    generation++;
    session = null;
    if (removeStored) {
      try { localStorage.removeItem(storageKey); } catch { storageAvailable = false; }
    }
    window.dispatchEvent(new Event("farmer:session-ended"));
  }
  function syncSession() {
    const saved = readStored();
    if (saved !== undefined) {
      if (session && session.id !== saved?.id) forgetSession(false);
      session = saved;
    }
    if (session && session.deadline <= Date.now()) forgetSession();
    return session;
  }
  function keepSession(value, previous = null) {
    if (!value?.access_token) return null;
    if (!value.refresh_token) throw loginRequired();
    // Persist only the token pair and expiry metadata, never a password or order data.
    session = {
      id: previous?.id || crypto.randomUUID(),
      access_token: value.access_token,
      refresh_token: value.refresh_token,
      expires_at: Date.now() + Number(value.expires_in || 3600) * 1000,
      deadline: previous?.deadline || Date.now() + sessionLifetime,
    };
    try { localStorage.setItem(storageKey, JSON.stringify(session)); }
    catch { storageAvailable = false; }
    return session;
  }
  async function refreshSession() {
    // Re-read inside the cross-tab lock: another tab may already have rotated the token.
    const run = async () => {
      syncSession();
      if (!session) throw loginRequired();
      if (session.expires_at > Date.now() + 60000) return;
      const previous = session, current = generation;
      try {
        const value = await request("/auth/v1/token?grant_type=refresh_token", { refresh_token: previous.refresh_token });
        const saved = readStored();
        if (current !== generation || (saved !== undefined && saved?.id !== previous.id)) throw loginRequired();
        if (previous.deadline <= Date.now()) { forgetSession(); throw loginRequired(); }
        keepSession(value, previous);
      } catch (error) {
        if ([400, 401, 403].includes(error.status)) {
          // Browsers without Web Locks can receive a token rotated by another tab.
          const saved = readStored();
          if (saved?.id === previous.id && saved.refresh_token !== previous.refresh_token && saved.expires_at > Date.now() + 60000) {
            session = saved;
            return;
          }
          if (current === generation && (saved === undefined || saved?.id === previous.id)) forgetSession();
          throw loginRequired();
        }
        // Offline/5xx failures keep the refresh token so retrying does not require a password.
        throw error;
      }
    };
    return navigator.locks?.request ? navigator.locks.request(storageKey, run) : run();
  }
  async function accessToken() {
    syncSession();
    if (!session) throw loginRequired();
    if (session.expires_at <= Date.now() + 60000) {
      if (!refreshing) {
        const pending = refreshSession().finally(() => { if (refreshing === pending) refreshing = null; });
        refreshing = pending;
      }
      await refreshing;
    }
    syncSession();
    if (!session) throw loginRequired();
    return session.access_token;
  }
  window.addEventListener("storage", (event) => {
    if (event.key === storageKey || event.key === null) syncSession();
  });
  window.FarmerAPI = Object.freeze({
    ready,
    restoreSession: () => !!syncSession(),
    hasSession: () => !!session,
    persistsSession: () => storageAvailable,
    rpc: (name, body = {}) => request("/rest/v1/rpc/" + name, body),
    admin: async (name, body = {}) => {
      const token = await accessToken(), current = generation;
      try { return await request("/rest/v1/rpc/" + name, body, token); }
      catch (error) {
        if ([401, 403].includes(error.status)) {
          if (current === generation) forgetSession();
          throw loginRequired();
        }
        throw error;
      }
    },
    signIn: async (email, password) => {
      const current = ++generation;
      const value = await request("/auth/v1/token?grant_type=password", { email, password });
      if (current !== generation) throw loginRequired();
      return keepSession(value);
    },
    signUp: async (email, password) => {
      const current = ++generation;
      const result = await request(
        "/auth/v1/signup?redirect_to=" +
          encodeURIComponent(location.origin + location.pathname),
        { email, password },
      );
      if (current !== generation) throw loginRequired();
      keepSession(result);
      return result;
    },
    signOut: async () => {
      const token = session?.access_token;
      forgetSession();
      if (token) await request("/auth/v1/logout?scope=local", {}, token).catch(() => {});
    },
    // An email confirmation can return a short-lived session in the URL fragment.
    consumeCallback: () => {
      const p = new URLSearchParams(location.hash.slice(1));
      if (!p.get("access_token")) return false;
      keepSession({
        access_token: p.get("access_token"),
        refresh_token: p.get("refresh_token"),
        expires_in: Number(p.get("expires_in") || 3600),
      });
      history.replaceState(null, "", location.pathname + location.search);
      return true;
    },
    uuid: () => crypto.randomUUID(),
  });
})();
