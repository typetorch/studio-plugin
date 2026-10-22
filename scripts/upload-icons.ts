/**
 * Uploads the toolbar icons (assets/icons/*.png) to Roblox as Images through Open Cloud and writes their ids into
 * src/TypeTorch/Icons.luau. Toolbar buttons only take rbxassetid:// images, so this runs once per icon change:
 *
 *   bun scripts/upload-icons.ts --user <your user id>  [--env-file <game repo>/.env]
 *   bun scripts/upload-icons.ts --group <group id>     [--env-file ...]
 *
 * The key comes from OPENCLOUD_ASSETS_KEY, else OPENCLOUD_API_KEY / ROBLOX_API_KEY (environment or --env-file): it
 * needs asset:read and asset:write for that user or group (a TypeTorch game's assets key works).
 */
import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const ICONS = ["idle", "connecting", "synced", "error", "claude"] as const;
const root = resolve(import.meta.dir, "..");
const args = process.argv.slice(2);
const flag = (name: string) => {
	const i = args.indexOf(`--${name}`);
	return i >= 0 ? args[i + 1] : undefined;
};

const env: Record<string, string | undefined> = { ...process.env };
const envFile = flag("env-file");
if (envFile) {
	for (const line of readFileSync(envFile, "utf8").split(/\r?\n/)) {
		const m = /^\s*(?:export\s+)?([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
		if (m && env[m[1]] === undefined) env[m[1]] = m[2].replace(/^(['"])(.*)\1$/, "$2");
	}
}
const key = env.OPENCLOUD_ASSETS_KEY ?? env.OPENCLOUD_API_KEY ?? env.ROBLOX_API_KEY;
if (!key) throw new Error("no key: set OPENCLOUD_ASSETS_KEY (or pass --env-file with one)");
const user = flag("user");
const group = flag("group");
if (!user === !group || !/^\d+$/.test(user ?? group ?? "")) throw new Error("pass --user <id> or --group <id>");
const creator = user ? { userId: user } : { groupId: group };

async function call(method: string, path: string, body?: FormData) {
	const res = await fetch(`https://apis.roblox.com${path}`, { method, headers: { "x-api-key": key! }, body });
	const text = await res.text();
	if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${text}`);
	return JSON.parse(text);
}

async function upload(name: string): Promise<string> {
	const form = new FormData();
	form.append("request", JSON.stringify({ assetType: "Image", displayName: `TypeTorch ${name}`, description: "TypeTorch Studio plugin toolbar icon", creationContext: { creator } }));
	form.append("fileContent", new Blob([readFileSync(join(root, "assets", "icons", `${name}.png`))], { type: "image/png" }), `${name}.png`);
	const op = await call("POST", "/assets/v1/assets", form);
	const id = op.operationId ?? String(op.path ?? "").split("/").pop();
	for (let i = 0; i < 60; i++) {
		const state = await call("GET", `/assets/v1/operations/${id}`);
		if (state.done) {
			if (!state.response?.assetId) throw new Error(`${name}: ${JSON.stringify(state)}`);
			return String(state.response.assetId);
		}
		await Bun.sleep(1000);
	}
	throw new Error(`${name}: the upload didn't finish`);
}

const ids: Record<string, string> = {};
for (const name of ICONS) {
	ids[name] = await upload(name);
	console.log(`${name}: rbxassetid://${ids[name]}`);
}
const file = join(root, "src", "TypeTorch", "Icons.luau");
let source = readFileSync(file, "utf8");
for (const name of ICONS) source = source.replace(new RegExp(`(\\n\\t${name} = )"[^"]*"`), `$1"rbxassetid://${ids[name]}"`);
writeFileSync(file, source);
console.log(`wrote ${file}`);
