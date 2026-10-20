import { useNavigate } from "@solidjs/router";
import { onMount } from "solid-js";
import { PENDING_JOIN } from "~/lib/app";

/** `/join#<payload>`: the browser's form of a `typewright://join/<payload>` invite link. */
export default function Join() {
  const navigate = useNavigate();
  onMount(() => {
    const payload = location.hash.slice(1);
    if (payload) sessionStorage.setItem(PENDING_JOIN, `typewright://join/${payload}`);
    navigate("/", { replace: true });
  });
  return null;
}
