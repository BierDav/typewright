import { beforeEach, expect, test } from "bun:test";
import { createTemporaryIdentity, hex, identity, loadIdentity, onIdentityChange, signInWithKey, signOut } from "./identity";

const stored = new Map<string, string>();
Object.defineProperty(globalThis, "localStorage", { configurable: true, value: {
  getItem: (key: string) => stored.get(key) ?? null,
  setItem: (key: string, value: string) => { stored.set(key, value); },
  removeItem: (key: string) => { stored.delete(key); },
} });

beforeEach(() => {
  stored.clear();
  onIdentityChange(async () => {});
  signOut();
});

test("guest identity survives a reload", async () => {
  await createTemporaryIdentity();
  const secret = hex(identity.account!);
  const saved = stored.get("typewright.account")!;
  signOut();
  stored.set("typewright.account", saved);
  await loadIdentity();
  expect(identity.kind).toBe("temporary");
  expect(hex(identity.account!)).toBe(secret);
  expect(identity.account!.length).toBe(32);
});

test("prepares share transfer before replacing guest credentials", async () => {
  await createTemporaryIdentity();
  const guest = hex(identity.account!);
  const target = "ab".repeat(32);
  let prepared = false;
  onIdentityChange(async (account) => {
    expect(hex(identity.account!)).toBe(guest);
    expect(JSON.parse(stored.get("typewright.account")!).kind).toBe("temporary");
    expect(hex(account)).toBe(target);
    prepared = true;
  });
  await signInWithKey(target);
  expect(prepared).toBe(true);
  expect(identity.kind).toBe("key");
  expect(hex(identity.account!)).toBe(target);
});

test("failed preparation keeps the guest identity recoverable", async () => {
  await createTemporaryIdentity();
  const saved = stored.get("typewright.account");
  const guest = hex(identity.account!);
  onIdentityChange(async () => { throw new Error("Unable to save shares"); });
  await expect(signInWithKey("ab".repeat(32))).rejects.toThrow("Unable to save shares");
  expect(identity.kind).toBe("temporary");
  expect(hex(identity.account!)).toBe(guest);
  expect(stored.get("typewright.account")).toBe(saved);
});

test("invalid sign-in keeps the guest identity", async () => {
  await createTemporaryIdentity();
  const guest = hex(identity.account!);
  await signInWithKey("invalid");
  expect(hex(identity.account!)).toBe(guest);
  expect(identity.kind).toBe("temporary");
  expect(identity.error).toBeTruthy();
});
