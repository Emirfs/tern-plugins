# omp-artifacts

An [omp](https://github.com/can1357/oh-my-pi) extension (not a Tern plugin) that gives agents Claude-style
artifacts: standalone pages, images, diagrams, documents and code files shown beside the conversation, each
change kept as a new version.

## Install

Add it to each profile's `config.yml` (`~/.omp/agent/config.yml` for `default`,
`~/.omp/profiles/<name>/agent/config.yml` for the others):

```yaml
extensions:
  - <clone>/omp-artifacts/artifacts.ts
```

Or try it for one run: `omp -e <clone>/omp-artifacts/artifacts.ts`.

## Usage

- The model calls the `artifact` tool with an `id`, a `title`, a `type` (`html`, `svg`, `markdown`,
  `mermaid`, `code` with a `language`) and the full `content`. Calling it again with the same `id` saves the
  next version; title and type carry over when left out.
- Inside Tern, the artifact shows in a browser block docked to the right of the conversation. Every later
  artifact and version of the session reuses that block; if you close it, the next one opens a new block.
  Outside Tern the tool only reports the file's path.
- `/artifacts` lists the session's artifacts, newest first; pick one, then a version to show again. In
  Tern the version list also offers **Edit the source of vN in a file block**.
- `/artifacts <id>` shows the latest version, `/artifacts <id> v2` an older one.

Mermaid diagrams and code highlighting load mermaid and highlight.js from jsDelivr; offline, the source
shows as plain text.

## How it works

Versions are files in the session's artifacts directory (`ctx.sessionManager.getArtifactsDir()`, beside
the session file), one folder per artifact:

```
<session>/omp-artifacts/<id>/index.json      every version: title, type, files, time
<session>/omp-artifacts/<id>/v1.html         html: shown as written
<session>/omp-artifacts/<id>/v2.md           other types: the source ...
<session>/omp-artifacts/<id>/v2.view.html    ... and the page the viewer shows
```

Sessions without a session file (`--no-session`) keep them in `%TEMP%/omp-artifacts/<session id>`.

Tern's browser on Windows receives `file://` pages as `application/octet-stream` and shows nothing, so the
extension serves the session's folder on `127.0.0.1` (a random port, a random token in every address,
nothing else readable). The viewer opens with `tern browser` as a picture in picture over omp's pane and is
docked with `tern dock <block> right`: opening it docked directly would focus it and switch the window to
omp's session even when that runs in the background (in that case the picture in picture shows over the
window for a moment before it docks). When omp's tab is on screen, the block focused before gets the focus
back. After omp restarts on the same session, the old viewer is found by its address and reused.

## Tests

```sh
cd omp-artifacts && bun test
```

Tested with omp 18.22.0 and Tern 0.9.26 on Windows.
