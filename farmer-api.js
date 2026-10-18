/* Only a publishable/anon key belongs in farmer-config.js. Never add secret/service_role keys. */
(() => {
  "use strict";
  const config = window.FARMER_BACKEND || {};
  let session = null,
    refreshing = null,
    generation = 0;
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
        error.code = result?.code;
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
  function keepSession(value) {
    if (!value?.access_token) return null;
    session = { ...value, expires_at: Date.now() + value.expires_in * 1000 };
    return session;
  }
  async function accessToken() {
    if (!session) throw new Error("관리자 로그인이 필요합니다.");
    if (session.expires_at < Date.now() + 60000) {
      if (!refreshing) {
        const current = generation;
        refreshing = request("/auth/v1/token?grant_type=refresh_token", {
          refresh_token: session.refresh_token,
        })
          .then((value) => {
            if (current === generation) return keepSession(value);
          })
          .finally(() => (refreshing = null));
      }
      await refreshing;
    }
    if (!session) throw new Error("관리자 로그인이 필요합니다.");
    return session.access_token;
  }
  window.FarmerAPI = Object.freeze({
    ready,
    rpc: (name, body = {}) => request("/rest/v1/rpc/" + name, body),
    admin: async (name, body = {}) =>
      request("/rest/v1/rpc/" + name, body, await accessToken()),
    signIn: async (email, password) =>
      keepSession(
        await request("/auth/v1/token?grant_type=password", {
          email,
          password,
        }),
      ),
    signUp: async (email, password) => {
      const result = await request(
        "/auth/v1/signup?redirect_to=" +
          encodeURIComponent(location.origin + "/admin.html"),
        { email, password },
      );
      keepSession(result);
      return result;
    },
    signOut: async () => {
      const token = session?.access_token;
      generation++;
      session = null;
      if (token) await request("/auth/v1/logout", {}, token).catch(() => {});
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
