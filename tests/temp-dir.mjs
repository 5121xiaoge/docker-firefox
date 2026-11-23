import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { after } from "node:test";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const tempRoot = process.env.FIREFOX_TEST_TMPDIR || path.join(root, "temp", "tests");
const created = [];

// Creates a scratch directory that is removed after the test file finishes
// (set FIREFOX_TEST_KEEP=1 to keep them for debugging).
export function tempDir(prefix) {
    mkdirSync(tempRoot, { recursive: true });
    const directory = mkdtempSync(path.join(tempRoot, prefix));
    created.push(directory);
    return directory;
}

after(() => {
    if (process.env.FIREFOX_TEST_KEEP === "1") return;
    for (const directory of created) rmSync(directory, { recursive: true, force: true });
});
