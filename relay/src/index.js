// Tether relay — a tiny Cloudflare Worker + Durable Object.
// It pairs a viewer with a host by 9-digit ID and forwards encrypted bytes.
// It never sees passwords or screen contents (sessions are end-to-end encrypted).
import { DurableObject } from "cloudflare:workers";

const ID_RE = /^\d{9}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "/health") {
      return new Response("Tether relay is running.\n", { headers: { "content-type": "text/plain" } });
    }
    if (!["/host", "/connect", "/accept"].includes(url.pathname)) {
      return new Response("not found", { status: 404 });
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const id = url.searchParams.get("id") || "";
    if (!ID_RE.test(id)) return new Response("bad id", { status: 400 });
    const stub = env.HOSTS.get(env.HOSTS.idFromName(id));
    return stub.fetch(request);
  },
};

async function sha256hex(s) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomSid() {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

export class HostRoom extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    // Answer host keep-alives without waking the object.
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async checkSecret(secret, claim) {
    if (!secret || secret.length < 32 || secret.length > 256) return false;
    const h = await sha256hex(secret);
    const stored = await this.ctx.storage.get("secretHash");
    if (!stored) {
      if (!claim) return false;
      await this.ctx.storage.put("secretHash", h);
      return true;
    }
    return stored === h;
  }

  hostSocket() {
    return this.ctx.getWebSockets("host")[0] || null;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const ip = request.headers.get("CF-Connecting-IP") || "";
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    if (url.pathname === "/host") {
      if (!(await this.checkSecret(url.searchParams.get("secret"), true))) {
        return new Response("forbidden", { status: 403 });
      }
      for (const old of this.ctx.getWebSockets("host")) {
        try { old.close(4000, "replaced"); } catch {}
      }
      const lan = (url.searchParams.get("lan") || "").split(",")
        .filter((a) => /^[0-9.]{7,15}:\d{2,5}$/.test(a)).slice(0, 8);
      this.ctx.acceptWebSocket(server, ["host"]);
      server.serializeAttachment({ role: "host", ip, lan });
      return new Response(null, { status: 101, webSocket: client });
    }

    if (url.pathname === "/connect") {
      const host = this.hostSocket();
      this.ctx.acceptWebSocket(server, ["viewer"]);
      if (!host) {
        server.send(JSON.stringify({ t: "error", reason: "offline" }));
        server.close(4004, "offline");
        return new Response(null, { status: 101, webSocket: client });
      }
      const sid = randomSid();
      const h = host.deserializeAttachment() || {};
      server.serializeAttachment({ role: "viewer", sid, paired: false, ip });
      // Only reveal LAN addresses to viewers behind the same public IP.
      const same = ip && h.ip && ip === h.ip;
      server.send(JSON.stringify({ t: "info", lan: same ? h.lan || [] : [] }));
      return new Response(null, { status: 101, webSocket: client });
    }

    if (url.pathname === "/accept") {
      if (!(await this.checkSecret(url.searchParams.get("secret"), false))) {
        return new Response("forbidden", { status: 403 });
      }
      const sid = url.searchParams.get("sid") || "";
      const viewer = this.findViewer(sid);
      if (!viewer) return new Response("gone", { status: 410 });
      this.ctx.acceptWebSocket(server, ["data"]);
      server.serializeAttachment({ role: "data", sid });
      const va = viewer.deserializeAttachment();
      va.paired = true;
      viewer.serializeAttachment(va);
      viewer.send(JSON.stringify({ t: "ready" }));
      return new Response(null, { status: 101, webSocket: client });
    }
    return new Response("not found", { status: 404 });
  }

  findViewer(sid) {
    for (const ws of this.ctx.getWebSockets("viewer")) {
      const a = ws.deserializeAttachment();
      if (a && a.sid === sid) return ws;
    }
    return null;
  }

  findData(sid) {
    for (const ws of this.ctx.getWebSockets("data")) {
      const a = ws.deserializeAttachment();
      if (a && a.sid === sid) return ws;
    }
    return null;
  }

  peerOf(ws) {
    const a = ws.deserializeAttachment() || {};
    if (a.role === "viewer") return this.findData(a.sid);
    if (a.role === "data") return this.findViewer(a.sid);
    return null;
  }

  async webSocketMessage(ws, msg) {
    const a = ws.deserializeAttachment() || {};
    if (typeof msg === "string") {
      if (a.role === "viewer" && !a.paired) {
        let m = null;
        try { m = JSON.parse(msg); } catch {}
        if (m && m.t === "relay") {
          const host = this.hostSocket();
          if (!host) {
            ws.send(JSON.stringify({ t: "error", reason: "offline" }));
            ws.close(4004, "offline");
            return;
          }
          host.send(JSON.stringify({ t: "incoming", sid: a.sid }));
        }
      }
      return; // other text (e.g. keep-alive) is ignored
    }
    const peer = this.peerOf(ws);
    if (peer) {
      try { peer.send(msg); } catch { try { ws.close(1011, "peer error"); } catch {} }
    }
  }

  async webSocketClose(ws, code, reason) {
    const peer = this.peerOf(ws);
    if (peer) { try { peer.close(1000, "peer closed"); } catch {} }
    try { ws.close(1000, "bye"); } catch {}
  }

  async webSocketError(ws) {
    await this.webSocketClose(ws, 1011, "error");
  }
}
