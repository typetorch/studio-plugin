# TypeTorch Studio plugin

Attaches Roblox Studio to [`typetorch serve`](https://github.com/typetorch/cli) by itself and keeps it synced: no
Connect button, no reconnecting by hand. It also lets an agent drive Studio (reconnect, play, stop, Output), pushes code
into a running playtest (kernel 0.5.4+), and publishes hot assets from a panel: select a model or UI, **Add**, then
**Publish to dev**, with no place publish first.

## Install

In a TypeTorch game repo:

```sh
bun add -d @typetorch/studio-plugin
bunx typetorch studio install-plugin
```

`install-plugin` builds this package with Rojo into Studio's plugins folder as `TypeTorchSync.rbxm`; restart Studio
(or reload plugins). From a checkout of this repo instead: `rojo build default.project.json --plugin TypeTorchSync.rbxm`
(or `typetorch studio install-plugin --from <this folder>`). Then run `typetorch serve` in the game folder: the plugin
finds it. The CLI's README ("Studio: typetorch serve") describes the whole loop.

## Working with someone else's serve

The owner runs `typetorch serve --remote` and points a tunnel at it (Cloudflare Tunnel: `service:
http://localhost:34890`), then `typetorch serve pair` for a one-time code. In the panel's **Remote server** card, enter
the tunnel URL and the code and press **Pair**; Studio then syncs from that serve (code read-only) and the Hot assets
buttons run there. **Use local serve** goes back. See the CLI's README ("A Studio on another machine").

## Claude

The toolbar's **Claude** button opens a chat with Claude Code on the machine that runs `typetorch serve --claude`
(remote-claude from `@typetorch/dev-server`), like the in-game DEV > Claude tab: it edits that serve's dev branch, and
when it's done you choose **Deploy** or **Discard**. It works with a local serve and with a paired remote one (pair
again after updating the plugin, so serve knows your Roblox user; the owner adds your user id with
`--claude-users`). Claude acting inside Studio itself isn't there yet.

## Layout

The control API's contract is `src/serve/protocol.ts` in typetorch/cli; the two must change together.

- `src/Main.server.luau`: the plugin script.
- `src/TypeTorch/App.luau`: finds the server (`GET /tt/hello` on 34880-34887), picks the one whose universeId matches
  the place, runs Rojo's sync, reconnects, reports to the server. In a playtest's server it syncs into the running game
  and sets `ServerStorage.TypeTorchDev`'s `LiveReload` attribute, which makes the kernel (0.5.4+) reload on changes.
- `src/TypeTorch/Agent.luau`: in every DataModel (edit, playtest server and client): runs the commands an agent sends
  through `typetorch studio` / `typetorch mcp` (long poll on `/tt/plugin/poll`), forwards Studio's Output, and in edit
  mode reconnects when the `TypeTorchReconnect` attribute is set on ServerStorage.
- `src/TypeTorch/Assets.luau`: hot assets in the place (add, remove, the sync's rules) and their export from the open
  place (`SerializationService`, the same format as the CLI's export task); the panel's Check / Upload / Publish to dev
  buttons send that export to `typetorch serve` as a job (`POST /tt/jobs`, `assets status|sync --studio-export`).
- `src/TypeTorch/Icons.luau`: the toolbar button's icon per connection state (gray waiting, amber connecting, green
  synced, red disconnected): `rbxassetid://<id>` of each image, once the TypeTorch icon set is picked and uploaded.
  An empty id keeps Studio's default icon.
- `src/TypeTorch/Panel.luau`, `Widgets.luau`: the dock widget, in the TypeTorch dev menu's look.
- `src/TypeTorch/Claude.luau`: the Claude window (`/tt/claude/...` on serve, which talks to remote-claude).
- `src/TypeTorch/Control.luau`: the control API client (cli `src/serve/protocol.ts` is the contract): a local port, or
  a paired remote serve (its URL plus a device token; Rojo at `<url>/r/<token>`).
- `vendor/rojo/`: Rojo's plugin core, unchanged except where marked.

## Rojo (vendored, MPL-2.0)

`vendor/rojo/` is the plugin core of [Rojo](https://github.com/rojo-rbx/rojo) **7.7.0-rc.1** (the version
`rokit.toml` pins in TypeTorch games), so it speaks the same protocol as `rojo serve`: `plugin/src` without the
Roact UI (`App/`), assets, sounds, tests and its entry script, plus its packages `http`, `log`, `fmt`, `rbx_dom_lua`
(without `allValues.json`, used only by tests), Promise and t. Those files are under the Mozilla Public License 2.0
(`vendor/rojo/LICENSE.txt`); Promise and t keep their own licenses next to them.

Changed files (MPL-2.0 still applies to them, and each says what changed at its top):

- `Plugin/Settings.lua`: no Roact (`getBinding`/`getBindings` removed); settings are stored as `TypeTorchRojo_<name>`
  so they never mix with the stock Rojo plugin's.

To update Rojo: copy the same files from the new tag, re-apply the change above, and keep `Version.txt` in step with
the `rojo` that `rokit.toml` pins.

## License

MIT (`LICENSE`), except `vendor/rojo/` (MPL-2.0, see above).
