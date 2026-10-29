import { nativeConfig, invokeNative, listenNative } from "./native";
import { base64url, unbase64url } from "./handoff";

export type ScrollPhase = { phase: number; momentum: number; dx: number; dy: number; x: number; y: number };

// The desktop host owns windows, native dialogs and the library; absent on the web.
type Desktop = {
  platform: string;
  packageLinks(): Promise<string[]>;
  unlinkPackages(namespace: string): Promise<void>;
  packageFolder(): Promise<{ folder: string; manifests: { target: string; toml: string }[] } | null>;
  linkPackages(namespace: string, folder: string, packages: { target: string; name: string; version: string }[]): Promise<void>;
  hoverButtons(rect: { x: number; y: number; width: number; height: number }): void;
  windowControl(action: "close" | "minimize" | "zoom"): void;
  setTheme(theme: "system" | "light" | "dark"): void;
  reveal(path: string): void;
  scrollPhases?(listener: (event: ScrollPhase) => void): Promise<() => void>;
  passkey?(mode: "create" | "get", name: string): Promise<{ secret: string; name: string } | null>;
};

async function browserPasskey(mode: "create" | "get", name: string): Promise<{ secret: string; name: string } | null> {
  const keys = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveKey"]);
  const state = base64url(crypto.getRandomValues(new Uint8Array(16)));
  const key = base64url(new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey)));
  return new Promise(async (resolve, reject) => {
    let unlisten: (() => void) | undefined;
    const finish = (value: { secret: string; name: string } | null) => { clearTimeout(timer); unlisten?.(); resolve(value); };
    const timer = setTimeout(() => finish(null), 10 * 60_000);
    try {
      unlisten = await listenNative<string>("passkey-link", async (url) => {
        try {
          const reply = JSON.parse(new TextDecoder().decode(unbase64url(new URL(url).hash.slice(1))));
          if (reply.state !== state) return;
          const browser = await crypto.subtle.importKey("raw", unbase64url(reply.key), { name: "ECDH", namedCurve: "P-256" }, false, []);
          const shared = await crypto.subtle.deriveKey({ name: "ECDH", public: browser }, keys.privateKey, { name: "AES-GCM", length: 256 }, false, ["decrypt"]);
          const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: unbase64url(reply.iv), additionalData: new TextEncoder().encode(state) }, shared, unbase64url(reply.data));
          const account = JSON.parse(new TextDecoder().decode(plain));
          if (/^[0-9a-f]{64}$/.test(account.secret)) finish({ secret: account.secret, name: String(account.name ?? "") });
        } catch { /* Ignore links that don't authenticate against this request. */ }
      });
      const payload = base64url(new TextEncoder().encode(JSON.stringify({ v: 1, mode, name, key, state })));
      await invokeNative("open_url", { url: `https://bierdav.github.io/typewright/passkey#${payload}` });
    } catch (error) { clearTimeout(timer); unlisten?.(); reject(error); }
  });
}

export const desktop: Desktop | undefined = nativeConfig ? {
  platform: nativeConfig.platform,
  packageLinks: () => invokeNative("package_links"),
  unlinkPackages: (namespace) => invokeNative("unlink_packages", { namespace }),
  packageFolder: () => invokeNative("package_folder"),
  linkPackages: (namespace, folder, packages) => invokeNative("link_packages", { namespace, folder, packages }),
  hoverButtons: (rect) => { void invokeNative("hover_buttons", rect); },
  windowControl: (action) => { void invokeNative("window_control", { action }); },
  setTheme: (theme) => { void invokeNative("theme", { theme }); },
  reveal: (path) => { void invokeNative("reveal", { path }); },
  ...(nativeConfig.nativeScroll ? { scrollPhases: (listener: (event: ScrollPhase) => void) => listenNative("scroll-phase", listener) } : {}),
  ...(nativeConfig.platform === "darwin" ? { passkey: nativeConfig.nativePasskey
    ? (mode: "create" | "get", name: string) => invokeNative<{ secret: string; name: string } | null>("native_passkey", { mode, name })
    : browserPasskey } : {}),
} : undefined;

if (desktop?.platform === "darwin") document.documentElement.classList.add("desktop-mac");
if (desktop) document.addEventListener("mousedown", (event) => {
  if (event.button !== 0 || (event.target as HTMLElement).closest("button, input, a, select, textarea")) return;
  const header = (event.target as HTMLElement).closest(".sidebar-header");
  if (header || event.clientY < 10) void invokeNative(event.detail === 2 ? "zoom_window" : "drag_window");
});
