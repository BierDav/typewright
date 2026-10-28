import { expect, mock, test } from "bun:test";
import { createTemporaryIdentity, hex, identity, signInWithKey } from "./identity";

const stored = new Map<string, string>();
Object.defineProperty(globalThis, "localStorage", { configurable: true, value: {
  getItem: (key: string) => stored.get(key) ?? null,
  setItem: (key: string, value: string) => { stored.set(key, value); },
  removeItem: (key: string) => { stored.delete(key); },
} });
Object.defineProperty(globalThis, "navigator", { configurable: true, value: {} });
const joined: unknown[][] = [];
const secret = "cd".repeat(32);
const fakeNode = {
  deviceId: () => "browser", snapshot: async () => new Uint8Array(), stop: async () => {},
  openShare: () => {}, shareInvite: () => secret,
  joinShare: (...args: unknown[]) => { joined.push(args); },
};
mock.module("~/wasm/sync/sync.js", () => ({
  default: async () => {}, generateDeviceKey: () => new Uint8Array(32), SyncNode: { start: async () => fakeNode },
}));
mock.module("~/wasm/sync/sync_bg.wasm?url", () => ({ default: "sync.wasm" }));
mock.module("./jj", () => ({ repository: { status: "open", conflicted: [] }, whenOpen: async () => {} }));
mock.module("./storage", () => ({
  readFile: async () => null, readText: async () => null, writeFile: async () => {}, remove: async () => {},
  basename: (path: string) => path.split("/").at(-1),
}));
mock.module("./spaces", () => ({ SPACES: "spaces", refreshSpaces: async () => {}, uniqueName: async (_root: string, name: string) => name }));
mock.module("./settings", () => ({ settings: { deviceName: "Browser" } }));
mock.module("./core", () => ({ shareStatus: () => "Synced" }));
const service = await import("./sync");

test("guest shares rejoin the signed-in account with their secret and destination", async () => {
  await createTemporaryIdentity();
  await service.restart();
  service.setSync("shares", "share-id", { path: "Library/Invited", kind: "folder" });
  service.setSync("shared", "share-id", ["browser", "owner"]);
  await signInWithKey("ab".repeat(32));
  const transfer = JSON.parse(stored.get("typewright.guestShareTransfer")!);
  expect(transfer.account).toBe(hex(identity.account!));
  expect(transfer.invites[0].invite.secret).toBe(secret);
  expect(transfer.invites[0].invite.hints).toEqual(["owner"]);
  await service.restart();
  expect(joined.at(-1)).toEqual(["share-id", "Invited", "folder", secret, ["owner"], "Browser"]);
  expect(service.pathOf("share-id")).toBe("Library/Invited");
  // An unconfirmed transfer retries after restarting instead of losing the share.
  await service.restart();
  expect(joined.length).toBe(2);
  await service.stop();
});

test("summary reports discovery and prioritizes active downloads", () => {
  service.setSync({ status: "running", connected: [], statuses: {} });
  expect(service.statusSummary()).toBe("Looking for peers…");
  service.setSync("statuses", "share-id", "Downloading");
  expect(service.statusSummary()).toBe("Downloading…");
  service.setSync("statuses", "share-id", "Applying changes");
  expect(service.statusSummary()).toBe("Applying changes…");
  service.setSync("statuses", "share-id", "Uploading");
  expect(service.statusSummary()).toBe("Uploading…");
  service.setSync("statuses", "share-id", "Synced");
  service.setSync("connected", ["owner"]);
  expect(service.statusSummary()).toBe("Synced");
});
