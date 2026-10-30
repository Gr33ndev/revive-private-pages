# revive-private-pages

**Bring the GitHub Pages sites of your private repositories back online — in one command.**

When a GitHub Pro / GitHub Education (Student Developer Pack) plan lapses or gets renewed, the Pages sites of **private** repositories can silently disappear: they return `404`, while the repository settings still claim the site is *built*. Re-saving every repo by hand is tedious. This tool finds all affected sites and revives them automatically.

```bash
curl -fsSL https://raw.githubusercontent.com/Gr33ndev/revive-private-pages/main/install.sh | bash
```

The installer checks everything you need, asks before it changes anything, and offers to run a read-only check right away.

---

## Contents

- [What it does](#what-it-does)
- [Installation](#installation)
- [Usage](#usage)
- [How the fixes work](#how-the-fixes-work)
- [Archived repositories](#archived-repositories)
- [Safety](#safety)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## What it does

1. Lists all your **private** repositories that have GitHub Pages configured.
2. Requests every site and marks those that do not answer with HTTP `200` as **offline**.
3. Tries fixes on **one test repository**, from least to most invasive, until the site is back.
4. Applies the fix that worked to all other offline sites.
5. Every site that still fails gets a **retry**, then **every other fix**, one after another — until it is online or all fixes have been tried. One run is enough.

```
✘ you/portfolio (HTTP 404)
✘ you/side-project (HTTP 404)
✔ you/notes

── Testing A) re-trigger build
  Waiting up to 240s for 1 site(s) ........................
  ✘ you/portfolio still offline after 240s
── Testing B) empty commit
  ...
── Testing C) disable/enable Pages
  ✔ you/portfolio is online
  → C) disable/enable Pages works.

══ C) disable/enable Pages for 1 repo(s)
  ✔ you/side-project is online

================ Summary ================
Back online: 2/2
Still offline: 0
```

## Installation

### One-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/Gr33ndev/revive-private-pages/main/install.sh | bash
```

The installer will:

| Step | What happens |
|------|--------------|
| 1 | Check for `gh`, `jq` and `curl`, and offer to install missing ones (Homebrew, apt, dnf, pacman, zypper or apk) |
| 2 | Check that `gh` is logged in with the scopes `repo` and `workflow`, and offer to log in or add missing scopes |
| 3 | Install `revive-private-pages` to `~/.local/bin` |
| 4 | Offer a read-only check of your repositories, then offer to fix them |

Prefer to read scripts before piping them into a shell? Good habit:

```bash
curl -fsSL https://raw.githubusercontent.com/Gr33ndev/revive-private-pages/main/install.sh -o install.sh
less install.sh
bash install.sh
```

Install somewhere else with `INSTALL_DIR=/some/dir bash install.sh`.

### Manual

```bash
git clone https://github.com/Gr33ndev/revive-private-pages.git
cd revive-private-pages
./revive-private-pages.sh --check
```

**Requirements:** [GitHub CLI](https://cli.github.com) (`gh`, logged in with `gh auth login -s repo,workflow`), [`jq`](https://jqlang.org), `curl`, Bash 3.2 or newer. Works on macOS, Linux and WSL.

## Usage

```bash
revive-private-pages --check        # only list offline sites, change nothing
revive-private-pages                # find and fix offline sites
revive-private-pages --from C       # skip the test, start with fix C
```

| Option | Description | Default |
|--------|-------------|---------|
| `--check` | Only list offline sites, change nothing | |
| `--test OWNER/REPO` | Repository to try the fixes on first | first offline repo that is neither archived nor your `*.github.io` site |
| `--from A\|B\|C\|D` | Skip testing and start with this fix | |
| `--timeout SEC` | How long to wait for sites to come back after a fix | `240` |
| `--wait SEC` | How long a repository stays public in fix D | `5` |
| `--cooldown SEC` | Pause before retrying a fix that errored (e.g. rate limits) | `30` |
| `--all` | Also include repositories you access as collaborator or org member | only your own |
| `-h`, `--help` | Show help | |
| `-v`, `--version` | Show version | |

**Exit codes:** `0` all sites online · `1` error, or a repository could not be made private again · `2` some sites are still offline (with `--check`: offline sites were found).

## How the fixes work

| Fix | What it does | Side effects |
|-----|--------------|--------------|
| **A** re-trigger build | Requests a new Pages build (branch deployments) or re-runs / dispatches the latest Pages workflow (GitHub Actions deployments) | none |
| **B** empty commit | Creates an empty commit `chore: redeploy GitHub Pages` on the Pages branch via the GitHub API — no clone needed | one extra commit in the history |
| **C** disable/enable Pages | Saves the Pages configuration (source branch, path, custom domain, HTTPS setting), disables Pages and re-enables it with the same configuration | site is briefly unavailable (it is offline anyway) |
| **D** public → private | Makes the repository public for a few seconds and then private again | **code and history briefly public, stars and watchers are removed** — always asks first |

In practice, **fix C** is usually the one that brings sites back, but the tool always tries the gentler ones first on a single test repository.

## Archived repositories

Archived repositories are read-only, so none of the fixes can be applied to them directly. For every offline site in an archived repository, the tool asks whether you still need it:

```
Do you still need the site of you/old-project? [y/N]
```

Repositories you answer `y` for are unarchived for the fix and **archived again afterwards** — also if the run fails or you press `Ctrl+C`. Pressing Enter skips the repository.

## Safety

- **`--check` never changes anything.** Start with it.
- Fix **D** is never applied without you typing `yes`. Before you do: if a secret (token, API key, password) was *ever* committed to one of the listed repositories, remove it from the history or rotate it — bots scan newly public repositories within seconds.
- If the tool is interrupted while a repository is public, it makes it private again before exiting. Repositories that could not be made private are listed at the end in red, together with the command to fix them.
- If Pages could not be re-enabled after fix C, the summary lists the repository and its saved configuration so you can turn it back on under **Settings → Pages**.
- Only your own repositories are touched unless you pass `--all`.

## Troubleshooting

**`gh: Resource not accessible by integration` / `HTTP 403`**
Your token is missing scopes. Run `gh auth refresh -s repo,workflow`.

**`secondary rate limit`**
GitHub throttles many requests in a short time. The tool retries automatically after `--cooldown` seconds; for many repositories, increase it (e.g. `--cooldown 60`).

**A site is still offline after the run**
Some sites take longer than the timeout to come back. Wait a few minutes and run `revive-private-pages --check`. The summary also shows the last error for every site that is still offline.

**`mapfile: command not found` or similar on macOS**
You are running an old copy. This version works with the default macOS Bash 3.2.

## License

[MIT](LICENSE) © Gilian Rehm
