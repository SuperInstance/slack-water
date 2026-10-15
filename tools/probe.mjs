import { chromium } from "playwright-core";
const CHROME = "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe";
try {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: false,
    args: ["--no-first-run", "--no-default-browser-check", "--window-size=1280,800"],
  });
  const page = await browser.newPage();
  await page.goto("https://example.com", { timeout: 45000 });
  console.log("PROBE_OK title:", await page.title());
  await page.screenshot({ path: "/tmp/probe.png" });
  console.log("screenshot written");
  await browser.close();
} catch (e) {
  console.log("PROBE_FAIL:", String(e).slice(0, 300));
}
