// The desktop app's bridge (desktopApp/preload.cjs); absent in the browser.
type Desktop = {
  platform: string;
  /** Shows or hides macOS's window buttons, which sit inside the sidebar. */
  setTrafficLights(visible: boolean): void;
  /** Lets the window's own chrome (title bar, scroll bars, menus) follow the app's theme. */
  setTheme(theme: "system" | "light" | "dark"): void;
  /** Runs a passkey in the default browser and returns the account it gives (macOS only); null when cancelled. */
  passkey?(mode: "create" | "get", name: string): Promise<{ secret: string; name: string } | null>;
};

export const desktop: Desktop | undefined = typeof window === "undefined" ? undefined : (window as unknown as { typewrightDesktop?: Desktop }).typewrightDesktop;

// Styles that make room for the window buttons.
if (desktop?.platform === "darwin") document.documentElement.classList.add("desktop-mac");
