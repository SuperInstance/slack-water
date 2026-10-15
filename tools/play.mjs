#!/usr/bin/env node
/**
 * Playtest driver for Slack Water.
 *
 * Connects to a Chrome you can WATCH, drives the Roblox web client, and saves
 * screenshots so the loop is: look -> act -> look.
 *
 * Not shipped with the game. This is a playtest harness, not a product.
 *
 * Why Chrome on Windows rather than a headless browser in WSL: you want to
 * watch this happen, and a headless browser in a WSL terminal would show you
 * nothing. A headed Chrome launched from WSL opens on the Windows desktop, so
 * the game is visible while it is being driven.
 *
 * Roblox's client is a WebGL canvas, so there is no DOM to assert against.
 * Everything here is coordinates, keys and screenshots — which means the loop
 * is genuinely eyes-on, the same way a human playtest is.
 *
 * Usage:
 *   node play.mjs launch          start Windows Chrome with CDP enabled
 *   node play.mjs shot <name>     screenshot the live tab
 *   node play.mjs click <x> <y>   click
 *   node play.mjs hold <ms>       hold the mouse down, then release
 *   node play.mjs key <key>       press a key (Space, Enter, ...)
 *   node play.mjs goto <url>      navigate
 *   node play.mjs state           dump what tabs are open
 */

import { chromium } from "playwright-core";
import { spawn } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const CDP_PORT = 9222;
const CDP_URL = `http://127.0.0.1:${CDP_PORT}`;
const SHOTS = join(process.cwd(), "shots");
const CHROME = "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe";

function log(...args) {
  console.log("[play]", ...args);
}

async function connect() {
  const browser = await chromium.connectOverCDP(CDP_URL);
  const contexts = browser.contexts();
  if (contexts.length === 0) throw new Error("Chrome is up but exposed no contexts");
  const context = contexts[0];
  const pages = context.pages();
  const page = pages[0] ?? (await context.newPage());
  return { browser, context, page };
}

async function shot(page, name) {
  mkdirSync(SHOTS, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  const file = join(SHOTS, `${stamp}_${name}.png`);
  await page.screenshot({ path: file });
  log("shot ->", file);
  return file;
}

const [command, ...args] = process.argv.slice(2);

switch (command) {
	case "launch": {
		log("starting Windows Chrome with CDP on", CDP_PORT);
		// --user-data-dir must be a WINDOWS path since this is the Windows
		// binary; a /home/... path would not exist on its side.
		const profileDir = "C:\\Users\\casey\\AppData\\Local\\Temp\\slack-water-chrome";
		const child = spawn(
			CHROME,
			[
				`--remote-debugging-port=${CDP_PORT}`,
				`--user-data-dir=${profileDir}`,
				"--no-first-run",
				"--no-default-browser-check",
				"--window-size=1280,800",
				"https://www.roblox.com/games",
			],
			{ detached: true, stdio: "ignore" },
		);
		child.unref();
		log("chrome pid", child.pid);
		log("give it a few seconds, then run: node play.mjs state");
		break;
	}

	case "state": {
		const { browser, page } = await connect();
		log("title:", await page.title());
		log("url:", page.url());
		const size = page.viewportSize();
		log("viewport:", JSON.stringify(size));
		await browser.close();
		break;
	}

	case "goto": {
		const { browser, page } = await connect();
		await page.goto(args[0], { waitUntil: "domcontentloaded", timeout: 60_000 });
		log("navigated to", page.url());
		await page.waitForTimeout(6000);
		await shot(page, "goto");
		await browser.close();
		break;
	}

	case "shot": {
		const { browser, page } = await connect();
		await shot(page, args[0] ?? "frame");
		await browser.close();
		break;
	}

	case "click": {
		const { browser, page } = await connect();
		await page.mouse.click(Number(args[0]), Number(args[1]));
		log("clicked", args[0], args[1]);
		await page.waitForTimeout(1500);
		await shot(page, "after-click");
		await browser.close();
		break;
	}

	case "hold": {
		const { browser, page } = await connect();
		const ms = Number(args[0] ?? 1000);
		const x = Number(args[1] ?? 640);
		const y = Number(args[2] ?? 400);
		await page.mouse.move(x, y);
		await page.mouse.down();
		log("holding for", ms, "ms");
		// Screenshot mid-hold: this is the only way to see a minigame's
		// in-flight state, which is exactly when it matters.
		await page.waitForTimeout(Math.min(ms, 800));
		await shot(page, "mid-hold");
		await page.waitForTimeout(Math.max(0, ms - 800));
		await page.mouse.up();
		await page.waitForTimeout(1200);
		await shot(page, "after-hold");
		await browser.close();
		break;
	}

	case "key": {
		const { browser, page } = await connect();
		await page.keyboard.press(args[0] ?? "Space");
		log("pressed", args[0]);
		await page.waitForTimeout(1200);
		await shot(page, "after-key");
		await browser.close();
		break;
	}

	case "resize": {
		const { browser, page } = await connect();
		await page.setViewportSize({ width: Number(args[0]), height: Number(args[1]) });
		log("resized");
		await shot(page, "resized");
		await browser.close();
		break;
	}

	default:
		log("commands: launch | state | goto <url> | shot <name> | click <x> <y> | hold <ms> [x] [y] | key <k> | resize <w> <h>");
		process.exit(1);
}

// never leave a dangling handle
process.on("exit", () => process.exit(0));