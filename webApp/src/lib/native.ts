import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export type NativeConfig = { library: string; platform: string; nativeScroll: boolean; nativePasskey?: boolean };
export const nativeConfig = typeof window === "undefined" ? undefined : (window as unknown as { __TYPEWRIGHT_NATIVE__?: NativeConfig }).__TYPEWRIGHT_NATIVE__;
export const invokeNative = invoke;
export function listenNative<T>(event: string, listener: (data: T) => void): Promise<() => void> {
  return listen<T>(event, ({ payload }) => listener(payload));
}
