// The account all of a user's devices share, backed by a passkey whose PRF output every key derives
// from, or by an account key copied over by hand. It matches the Mac app's `SyncIdentity` (relying party,
// salt, derivation and key format), so the same passkey or key signs in to the same account in both.
import { createStore } from "solid-js/store";
import { invokeNative } from "./native";
import { desktop } from "./desktop";

/** The Mac app's relying party; set `VITE_PASSKEY_DOMAIN` for other deployments. */
const PASSKEY_DOMAIN: string = import.meta.env.VITE_PASSKEY_DOMAIN || "bierdav.github.io";
const KEY = "typewright.account";
const encoder = new TextEncoder();

export type Kind = "passkey" | "key" | "temporary";

type Stored = { secret: string; name: string; kind?: Kind };

export const [identity, setIdentity] = createStore({
  account: null as Uint8Array | null,
  name: null as string | null,
  kind: null as Kind | null,
  fingerprint: null as string | null,
  working: false,
  error: null as string | null,
});

export function hex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function unhex(text: string): Uint8Array {
  return new Uint8Array(text.match(/../g)?.map((h) => parseInt(h, 16)) ?? []);
}

/** The relying party this page can use: the Mac app's when served from its domain, else this host. */
export function relyingParty(): string {
  // The desktop app's passkeys run in the browser, on the hosted web app's page.
  if (desktop?.passkey) return PASSKEY_DOMAIN;
  const host = location.hostname;
  return host === PASSKEY_DOMAIN || host.endsWith(`.${PASSKEY_DOMAIN}`) ? PASSKEY_DOMAIN : host;
}

/** Whether passkeys made here are the Mac app's, so both sign in to one account. */
export function sharesMacPasskeys(): boolean {
  return relyingParty() === PASSKEY_DOMAIN;
}

export function passkeysSupported(): boolean {
  if (desktop?.passkey) return true;
  return typeof PublicKeyCredential !== "undefined" && window.isSecureContext;
}

async function fingerprintOf(account: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", account as Uint8Array<ArrayBuffer>));
  const text = hex(digest.subarray(0, 4)).toUpperCase();
  return `${text.slice(0, 4)}-${text.slice(4)}`;
}

let prepareChange: ((account: Uint8Array) => Promise<void>) | undefined;

export function onIdentityChange(prepare: (account: Uint8Array) => Promise<void>) {
  prepareChange = prepare;
}

async function adopt(secret: Uint8Array, name: string, kind: Kind) {
  await prepareChange?.(secret);
  const stored = JSON.stringify({ secret: hex(secret), name, kind } satisfies Stored);
  if (desktop?.platform === "darwin" && kind !== "temporary") {
    const result = await invokeNative<{ error?: string } | null>("native_account", { request: stored });
    if (result?.error) throw new Error(result.error);
  }
  localStorage.setItem(KEY, stored);
  setIdentity({ account: secret, name, kind, fingerprint: await fingerprintOf(secret), error: null });
}

/** The account's secret as eight groups of eight hexadecimal digits, to sign in on a device without the passkey. */
export function accountKey(): string | null {
  return identity.account ? (hex(identity.account).match(/.{8}/g) ?? []).join("-") : null;
}

/** Guest credentials survive reloads until the user signs in. */
export function createTemporaryIdentity() {
  return adopt(random(32), "", "temporary");
}

/** Creates an account without a passkey; its key is the only way to sign in elsewhere. */
export function createWithKey() {
  return adopt(random(32), "", "key");
}

export async function signInWithKey(text: string) {
  const digits = text.replace(/[^0-9a-fA-F]/g, "");
  if (digits.length !== 64) {
    setIdentity("error", "An account key has 64 hexadecimal digits.");
    return;
  }
  await adopt(unhex(digits.toLowerCase()), "", "key");
}

export async function loadIdentity() {
  try {
    const native = desktop?.platform === "darwin" ? await invokeNative<Stored | null>("native_account", { request: "load" }) : null;
    const stored = native ?? JSON.parse(localStorage.getItem(KEY) ?? "null") as Stored | null;
    if (stored?.secret?.length === 64) {
      const account = unhex(stored.secret);
      // Accounts from before account keys were all passkeys.
      setIdentity({ account, name: stored.name, kind: stored.kind ?? "passkey", fingerprint: await fingerprintOf(account) });
    }
  } catch {}
}

export function signOut() {
  if (desktop?.platform === "darwin") void invokeNative("native_account", { request: "clear" });
  localStorage.removeItem(KEY);
  setIdentity({ account: null, name: null, kind: null, fingerprint: null });
}

/** Fixed so every device gets the same PRF output from the passkey. */
async function prfSalt(): Promise<Uint8Array<ArrayBuffer>> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode("typewright account v0")));
}

function random(count: number): Uint8Array<ArrayBuffer> {
  return crypto.getRandomValues(new Uint8Array(count));
}

/** HKDF-SHA256 of the PRF output with an empty salt, like CryptoKit's `HKDF.deriveKey`. */
async function deriveAccount(prf: ArrayBuffer): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", prf, "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: encoder.encode("typewright account v0") },
    key,
    256,
  );
  return new Uint8Array(bits);
}

type PrfResults = { prf?: { enabled?: boolean; results?: { first?: ArrayBuffer } } };

async function run(body: () => Promise<{ prf: ArrayBuffer; name: string }>) {
  setIdentity({ working: true, error: null });
  try {
    const { prf, name } = await body();
    await adopt(await deriveAccount(prf), name, "passkey");
  } catch (err) {
    // Dismissing the sheet isn't an error worth showing.
    if ((err as DOMException)?.name !== "NotAllowedError") setIdentity("error", (err as Error).message);
  } finally {
    setIdentity("working", false);
  }
}

/** The account a passkey gives, without signing in here: the page the desktop app sends to the browser uses it. */
export async function passkeyAccount(mode: "create" | "get", name = ""): Promise<{ secret: Uint8Array; name: string }> {
  const result = mode === "create" ? await createCredential(name.trim()) : await assert();
  return { secret: await deriveAccount(result.prf), name: result.name };
}

/** The desktop app runs the passkey in the default browser, on the relying party's domain. */
async function runInBrowser(mode: "create" | "get", name = "") {
  setIdentity({ working: true, error: null });
  try {
    const result = await desktop!.passkey!(mode, name.trim());
    if (result) await adopt(unhex(result.secret), result.name, "passkey");
  } catch (err) {
    // Dismissing the sheet isn't an error worth showing.
    if ((err as DOMException)?.name !== "NotAllowedError") setIdentity("error", (err as Error).message);
  } finally {
    setIdentity("working", false);
  }
}

/** Creates the account's passkey, named `name` (like an email address) in the password manager. */
export function createPasskey(rawName: string) {
  if (desktop?.passkey) return runInBrowser("create", rawName);
  return run(() => createCredential(rawName.trim()));
}

async function createCredential(name: string): Promise<{ prf: ArrayBuffer; name: string }> {
  const salt = await prfSalt();
  // The name rides along in the user handle, so signing in on another device recovers it.
  const userID = new Uint8Array([...random(16), ...encoder.encode(name).subarray(0, 48)]);
  const credential = (await navigator.credentials.create({
    publicKey: {
      rp: { id: relyingParty(), name: "Typewright" },
      user: { id: userID, name: name || "Typewright", displayName: name || "Typewright" },
      challenge: random(32),
      pubKeyCredParams: [
        { type: "public-key", alg: -7 },
        { type: "public-key", alg: -257 },
      ],
      authenticatorSelection: { residentKey: "required", userVerification: "required" },
      extensions: { prf: { eval: { first: salt } } } as AuthenticationExtensionsClientInputs,
    },
  })) as PublicKeyCredential | null;
  if (!credential) throw new Error("No passkey was created.");
  const results = credential.getClientExtensionResults() as PrfResults;
  if (results.prf?.results?.first) return { prf: results.prf.results.first, name };
  if (results.prf?.enabled === false) throw new Error("This passkey can't derive keys (no PRF support).");
  // Some authenticators only evaluate the PRF when signing in.
  return assert();
}

async function assert(): Promise<{ prf: ArrayBuffer; name: string }> {
  const credential = (await navigator.credentials.get({
    publicKey: {
      rpId: relyingParty(),
      challenge: random(32),
      userVerification: "required",
      extensions: { prf: { eval: { first: await prfSalt() } } } as AuthenticationExtensionsClientInputs,
    },
  })) as PublicKeyCredential | null;
  const prf = (credential?.getClientExtensionResults() as PrfResults | undefined)?.prf?.results?.first;
  if (!credential || !prf) throw new Error("This passkey can't derive keys (no PRF support).");
  const handle = new Uint8Array((credential.response as AuthenticatorAssertionResponse).userHandle ?? new ArrayBuffer(0));
  return { prf, name: handle.length > 16 ? new TextDecoder().decode(handle.subarray(16)) : "" };
}

export function signInWithPasskey() {
  if (desktop?.passkey) return runInBrowser("get");
  return run(assert);
}
