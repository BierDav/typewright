import { createSignal, onMount, Show } from "solid-js";
import { hex, passkeyAccount } from "~/lib/identity";
import { parseRequest, sealedLink } from "~/lib/handoff";

/** `/passkey#<request>`: the desktop app's passkey sign-in, run in the browser on the relying party's domain. */
export default function Passkey() {
  const request = parseRequest(location.hash.slice(1));
  const [state, setState] = createSignal<"ready" | "working" | "done" | "error">(request ? "ready" : "error");
  const [error, setError] = createSignal(request ? "" : "This link is incomplete. Start again from Typewright's Devices settings.");
  // Links shouldn't be reused: the request stays out of the history.
  onMount(() => history.replaceState(null, "", location.pathname));

  async function run() {
    if (!request) return;
    setState("working");
    try {
      const account = await passkeyAccount(request.mode, request.name);
      location.href = await sealedLink(request, hex(account.secret), account.name);
      setState("done");
    } catch (err) {
      setState("ready");
      // Dismissing the sheet just leaves the button to try again.
      if ((err as DOMException)?.name !== "NotAllowedError") setError((err as Error).message);
    }
  }

  return (
    <div class="handoff">
      <img src={`${import.meta.env.BASE_URL}logo.png`} alt="" width="96" height="96" />
      <h1>{request?.mode === "create" ? "Create a Passkey for Typewright" : "Sign In to Typewright"}</h1>
      <Show
        when={state() !== "done"}
        fallback={<p class="secondary">You're signed in. Return to Typewright; this tab can be closed.</p>}
      >
        <p class="secondary">The desktop app uses your passkey through this page, so it signs in to the same account as the Mac app and the web app.</p>
        <Show when={request}>
          <button class="button primary" disabled={state() === "working"} onClick={() => void run()}>
            {request?.mode === "create" ? "Create Passkey" : "Continue with Passkey"}
          </button>
        </Show>
      </Show>
      <Show when={error()}>
        <p class="handoff-error">{error()}</p>
      </Show>
    </div>
  );
}
