import { Match, Show, Switch } from "solid-js";
import * as syncService from "~/lib/sync";
import { Cloud, CloudOff, RefreshCw, TriangleAlert, Users } from "./icons";

/** A share's state beside its name: conflicts, syncing, offline, or synced (shared with others or not). */
export function SyncBadge(props: { path: string }) {
  const state = () => syncService.status(props.path);
  return (
    <Show when={syncService.isSynced(props.path)}>
      <Switch>
        <Match when={state() === "Conflicts"}>
          <span title="Conflicts to resolve"><TriangleAlert size={13} class="warning" aria-label="Conflicts" /></span>
        </Match>
        <Match when={state() === "Syncing"}>
          <span title="Syncing…"><RefreshCw size={13} class="secondary syncing" aria-label="Syncing" /></span>
        </Match>
        <Match when={state() === "Offline"}>
          <span title="None of the other devices is connected"><CloudOff size={13} class="secondary" aria-label="Offline" /></span>
        </Match>
        <Match when={syncService.isShared(props.path)}>
          <span title="Shared with others"><Users size={13} class="secondary" aria-label="Shared" /></span>
        </Match>
        <Match when={true}>
          <span title="Synced"><Cloud size={13} class="secondary" aria-label="Synced" /></span>
        </Match>
      </Switch>
    </Show>
  );
}

