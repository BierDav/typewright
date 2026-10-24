// Package repositories from GitHub. A browser can't run git and GitHub's archives refuse cross-origin reads, so the
// file list comes from GitHub's API and the files from raw.githubusercontent.com, which both allow them.
import * as core from "./core";
import * as fs from "./storage";

const API = "https://api.github.com/repos";
const RAW = "https://raw.githubusercontent.com";

async function api(url: string): Promise<any> {
  const response = await fetch(url, { headers: { Accept: "application/vnd.github+json" } });
  if (response.status === 404) throw new Error("The repository doesn't exist or isn't public.");
  if (response.status === 403 || response.status === 429) throw new Error("GitHub's rate limit is reached; try again in an hour.");
  if (!response.ok) throw new Error(`GitHub answered ${response.status}.`);
  return response.json();
}

/** Clones a GitHub repository (`owner/repo` or a link) into `@namespace`, as the Mac app does: a package repository
 * with a `typst.toml` becomes `<name>/<version>/`, one of `<name>/<version>/` folders becomes the whole namespace.
 * Returns what was added, e.g. `@local/my-lib:1.0.0`. */
export async function cloneFromGitHub(input: string, namespace: string): Promise<string> {
  const repo = core.packageGithubRepo(input);
  if (!repo) throw new Error(`“${input.trim()}” isn't a GitHub repository. Enter owner/repo or a link to it.`);
  const name = namespace.trim();
  if (!/^[A-Za-z_][A-Za-z0-9_-]*$/.test(name)) throw new Error(`“${name}” isn't a valid namespace. Use letters, digits, - and _.`);
  if (name === "preview") throw new Error("“preview” is Typst Universe's namespace.");

  const commit: string = (await api(`${API}/${repo}/commits/HEAD`)).sha;
  const tree = await api(`${API}/${repo}/git/trees/${commit}?recursive=1`);
  if (tree.truncated) throw new Error("The repository is too large to download here.");
  // Dot folders (.github, .gitignore) aren't part of a package.
  const paths: string[] = tree.tree
    .filter((entry: { type: string; path: string }) => entry.type === "blob" && !entry.path.split("/").some((part) => part.startsWith(".")))
    .map((entry: { path: string }) => entry.path);
  const raw = async (path: string) => {
    const response = await fetch(`${RAW}/${repo}/${commit}/${path.split("/").map(encodeURIComponent).join("/")}`);
    if (!response.ok) throw new Error(`Downloading ${path} failed (${response.status}).`);
    return new Uint8Array(await response.arrayBuffer());
  };

  let target: string, added: string, files: string[];
  if (paths.includes("typst.toml")) {
    const manifest = core.packageManifest(new TextDecoder().decode(await raw("typst.toml")));
    if (!manifest) throw new Error("The repository's typst.toml has no valid package name and version.");
    target = fs.join("packages", name, manifest.name, manifest.version);
    added = `@${name}/${manifest.name}:${manifest.version}`;
    files = paths;
  } else {
    const packages = core.namespacePackages(paths);
    if (!packages.length) throw new Error("The repository has no typst.toml, nor packages as <name>/<version>/ folders.");
    target = fs.join("packages", name);
    added = `@${name}`;
    files = paths.filter((path) => packages.some((folder) => path.startsWith(`${folder}/`)));
  }
  if (await fs.exists(target)) throw new Error(`${target.replace(/^packages\//, "@")} already exists.`);

  try {
    // A few downloads at a time keep large repositories from flooding the network.
    const queue = [...files];
    const worker = async () => {
      for (let path = queue.shift(); path !== undefined; path = queue.shift()) {
        await fs.writeFile(fs.join(target, path), await raw(path), true);
      }
    };
    await Promise.all(Array.from({ length: 8 }, worker));
  } catch (err) {
    await fs.remove(target, true).catch(() => {});
    throw err;
  }
  return added;
}
