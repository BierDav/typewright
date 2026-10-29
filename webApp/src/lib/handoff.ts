// The desktop app's passkeys run in the browser on the relying party's domain; this page hands the account back
// through a `typewright-desktop://passkey#…` link, encrypted to a key only the waiting app holds (lib/desktop.ts).

export const HANDOFF_SCHEME = "typewright-desktop";

export type HandoffRequest = { v: 1; mode: "create" | "get"; name: string; key: string; state: string };

const encoder = new TextEncoder();

export function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function unbase64url(text: string): Uint8Array<ArrayBuffer> {
  const plain = atob(text.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(plain, (c) => c.charCodeAt(0));
}

export function parseRequest(hash: string): HandoffRequest | null {
  try {
    const request = JSON.parse(new TextDecoder().decode(unbase64url(hash))) as HandoffRequest;
    return request.v === 1 && (request.mode === "create" || request.mode === "get") && request.key && request.state ? request : null;
  } catch {
    return null;
  }
}

/** ECDH with a fresh key against the app's, AES-GCM bound to the request's state. */
export async function sealedLink(request: HandoffRequest, secret: string, name: string): Promise<string> {
  const app = await crypto.subtle.importKey("raw", unbase64url(request.key), { name: "ECDH", namedCurve: "P-256" }, false, []);
  const own = (await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveKey"])) as CryptoKeyPair;
  const key = await crypto.subtle.deriveKey({ name: "ECDH", public: app }, own.privateKey, { name: "AES-GCM", length: 256 }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: encoder.encode(request.state) }, key, encoder.encode(JSON.stringify({ secret, name })));
  const reply = { state: request.state, key: base64url(new Uint8Array(await crypto.subtle.exportKey("raw", own.publicKey))), iv: base64url(iv), data: base64url(new Uint8Array(data)) };
  return `${HANDOFF_SCHEME}://passkey#${base64url(encoder.encode(JSON.stringify(reply)))}`;
}
