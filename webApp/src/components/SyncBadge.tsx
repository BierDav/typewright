import { Match, Show, Switch } from "solid-js";
import * as syncService from "~/lib/sync";
import { CloudOff, MonitorSmartphone, RefreshCw, TriangleAlert, Users } from "./icons";

/** Sharing stays visible while transfers and connection status change. */
export function SyncBadge(props: { path: string }) {
  const state = () => syncService.status(props.path);
  return (
    <Show when={syncService.isSynced(props.path) || syncService.isShared(props.path)}>
      <Show when={syncService.isSynced(props.path)}>
        <span title="Available on your devices"><MonitorSmartphone size={13} class="secondary" aria-label="Available on your devices" /></span>
      </Show>
      <Show when={syncService.isShared(props.path)}>
        <span title="Shared with others"><Users size={13} class="secondary" aria-label="Shared with others" /></span>
      </Show>
      <Switch>
        <Match when={state() === "Conflicts"}>
          <span title="Conflicts to resolve"><TriangleAlert size={13} class="warning" aria-label="Conflicts" /></span>
        </Match>
        <Match when={["Syncing", "Looking for peers", "Downloading", "Uploading", "Applying changes"].includes(state() ?? "")}>
          <span title={`${state()}…`}><RefreshCw size={13} class="secondary syncing" aria-label={state()} /></span>
        </Match>
        <Match when={state() === "Offline"}>
          <span title="None of the other devices is connected"><CloudOff size={13} class="secondary" aria-label="Offline" /></span>
        </Match>
      </Switch>
    </Show>
  );
}

