import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, readdirSync, utimesSync, writeFileSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { tempDir } from "./temp-dir.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const shell = process.env.FIREFOX_TEST_SHELL || "/bin/sh";
const bash = process.env.FIREFOX_TEST_BASH || (process.platform === "win32" ? shell : "/bin/bash");
const read = file => readFileSync(path.join(root, file), "utf8");
const installer = read("install.sh");
const heredoc = name => installer.split(`<<'${name}'\n`)[1].split(`\n${name}\n`)[0];
const services = text => text.slice(text.indexOf("\nservices:\n"), text.indexOf("\nvolumes:\n"));
const posix = file => file.replaceAll("\\", "/");

function install(directory, answers) {
    const tty = path.join(directory, "tty");
    writeFileSync(tty, answers);
    const result = spawnSync(bash, [posix(path.join(root, "install.sh"))], {
        encoding: "utf8",
        env: { ...process.env, FIREFOX_DIR: posix(directory), FIREFOX_TTY: posix(tty), FIREFOX_INSTALL_ONLY: "1" },
        timeout: 20000,
    });
    if (result.error) throw result.error;
    return result;
}

test("the installer stores the entered user, never a password, and rejects invalid names", () => {
    const directory = tempDir("install-");
    const result = install(directory, "\nbad user\nalice\n");
    assert.equal(result.status, 0, result.stderr);
    assert.equal((result.stdout.match(/用户名不能为空/g) || []).length, 2);
    const env = readFileSync(path.join(directory, ".env"), "utf8");
    assert.match(env, /^WEBAUTH_USER=alice$/m);
    assert.doesNotMatch(env, /PASSWORD|REDACTED/);
    assert.equal(spawnSync(bash, ["-n", posix(path.join(directory, "deploy.sh"))]).status, 0);
    assert.equal(readFileSync(path.join(directory, "compose.yaml"), "utf8"), heredoc("EOF_COMPOSE") + "\n");
});

test("re-running the installer keeps .env and backs up locally modified files only", () => {
    const directory = tempDir("install-");
    assert.equal(install(directory, "alice\n").status, 0);
    writeFileSync(path.join(directory, ".env"), "WEBAUTH_USER=kept\n");
    assert.equal(install(directory, "").status, 0);
    assert.ok(!readdirSync(directory).some(name => name.endsWith(".bak")));
    writeFileSync(path.join(directory, "compose.yaml"), "# local change\n");
    assert.equal(install(directory, "").status, 0);
    const saved = readdirSync(directory).filter(name => /^compose\.yaml\.\d{8}_\d{6}\.bak$/.test(name));
    assert.equal(saved.length, 1);
    assert.equal(readFileSync(path.join(directory, saved[0]), "utf8"), "# local change\n");
    assert.equal(readFileSync(path.join(directory, ".env"), "utf8"), "WEBAUTH_USER=kept\n");
});

test("the installer's embedded services match compose.ghcr.yaml exactly", () => {
    assert.equal(services(heredoc("EOF_COMPOSE")), services(read("compose.ghcr.yaml")));
});

test("all Compose files share the shutdown, exposure, credential and backup settings", () => {
    const files = ["compose.yaml", "compose.ghcr.yaml"].map(read);
    const backup = text => text.slice(text.indexOf("\n  backup:\n"), text.indexOf("\n    logging:", text.indexOf("\n  backup:\n")));
    const prefs = text => text.match(/^ {6}FF_PREF_\w+: .*$/gm).join("\n");
    for (const text of files) {
        assert.match(text, /SERVICES_GRACETIME: "25000"/);
        assert.match(text, /stop_grace_period: 30s/);
        assert.ok(text.includes('"${FIREFOX_BIND_IP:-127.0.0.1}:${FIREFOX_PORT:-5800}:5800"'));
        assert.doesNotMatch(text, /WEB_AUTHENTICATION_(USERNAME|PASSWORD)|pull_policy/);
        assert.equal(backup(text), backup(files[0]));
        assert.equal(prefs(text), prefs(files[0]));
    }
    assert.doesNotMatch(read(".env.example"), /PASSWORD|FIREFOX_BASE_IMAGE/);
    assert.match(read(".gitignore"), /^\/backup\/$/m);
});

test("deploy backup retention never deletes the daily archives", () => {
    const directory = tempDir("retention-");
    mkdirSync(path.join(directory, "backup"));
    for (let day = 1; day <= 7; day++) writeFileSync(path.join(directory, `backup/firefox_config_${day}.tgz`), "");
    for (let index = 0; index < 8; index++) {
        const file = path.join(directory, `backup/firefox_config_deploy_2026010${index}_000000.tgz`);
        writeFileSync(file, "");
        utimesSync(file, 1700000000 + index, 1700000000 + index);
    }
    const line = heredoc("EOF_DEPLOY").split("\n").find(text => text.startsWith("ls -1t backup/"));
    const result = spawnSync(bash, ["-c", line], { cwd: directory, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    const left = readdirSync(path.join(directory, "backup"));
    assert.equal(left.filter(name => /^firefox_config_[1-7]\.tgz$/.test(name)).length, 7);
    assert.deepEqual(left.filter(name => name.includes("deploy")).sort(),
        [3, 4, 5, 6, 7].map(index => `firefox_config_deploy_2026010${index}_000000.tgz`));
});

function dailyBackup(directory, prefix = "") {
    const command = read("compose.ghcr.yaml").split("      - |\n")[1].split("\n    logging:")[0]
        .split("\n").map(line => line.slice(8)).join("\n")
        .replaceAll("$$", "$").replaceAll("/backup", "backup").replaceAll("/data", "data")
        .replace("sleep 86400", "exit 0");
    const result = spawnSync(shell, ["-s"], {
        input: `sleep() { :; }\ndate() { echo 3; }\n${prefix}${command}`,
        cwd: directory, encoding: "utf8", timeout: 20000,
    });
    if (result.error) throw result.error;
    return result;
}

test("the daily backup excludes caches and keeps the previous archive when tar fails", () => {
    const directory = tempDir("daily-");
    mkdirSync(path.join(directory, "data/profile/cache2"), { recursive: true });
    mkdirSync(path.join(directory, "backup"));
    writeFileSync(path.join(directory, "data/profile/prefs.js"), "keep\n");
    writeFileSync(path.join(directory, "data/profile/cache2/entry"), "drop\n");
    assert.equal(dailyBackup(directory).status, 0);
    const listing = spawnSync("tar", ["tzf", "firefox_config_3.tgz"], { cwd: path.join(directory, "backup"), encoding: "utf8" });
    assert.match(listing.stdout, /profile\/prefs\.js/);
    assert.doesNotMatch(listing.stdout, /cache2\/entry/);

    writeFileSync(path.join(directory, "backup/firefox_config_3.tgz"), "previous");
    const failed = dailyBackup(directory, "tar() { echo partial > backup/.tmp.tgz; return 1; }\n");
    assert.equal(failed.status, 0);
    assert.equal((failed.stderr.match(/backup attempt \d failed/g) || []).length, 3);
    assert.equal(readFileSync(path.join(directory, "backup/firefox_config_3.tgz"), "utf8"), "previous");
    assert.ok(!existsSync(path.join(directory, "backup/.tmp.tgz")));
});

// Runs the generated deploy.sh against a recording docker stub injected via BASH_ENV.
const fakeDocker = `docker() {
    printf '%s\\n' "$*" >> "$FAKE_LOG"
    local last="\${*: -1}"
    case "$*" in
        "volume ls -q") printf '%s' "$FAKE_VOLUMES" ;;
        "compose config") echo "name: $FAKE_PROJECT" ;;
        "ps -aq --filter volume="*) printf '%s' "$FAKE_CONTAINERS" ;;
        *com.docker.compose.project*) case "$last" in old*) echo legacy ;; *) echo "$FAKE_PROJECT" ;; esac ;;
        *RestartPolicy*) echo always ;;
        *State.Running*) case "$last" in *off*) echo false ;; *) echo true ;; esac ;;
        "inspect -f {{.Name}} "*) echo "/name-$last" ;;
        *State.Health*) echo healthy ;;
        "run "*) [ "$FAKE_BACKUP_FAIL" != 1 ] || return 1; : > "backup/$last" ;;
        "compose ps -q firefox") echo cid ;;
        "compose exec -T firefox webauth-user list") printf '%s' "$FAKE_USERS" ;;
    esac
}
`;

function deploy(env, fake = {}) {
    // The Compose project name deliberately differs from the directory name.
    const directory = tempDir("Deploy.");
    assert.equal(install(directory, "alice\n").status, 0);
    if (env !== undefined) writeFileSync(path.join(directory, ".env"), env);
    const stub = path.join(directory, "fake-docker.sh");
    writeFileSync(stub, fakeDocker);
    const log = path.join(directory, "docker.log");
    writeFileSync(log, "");
    const result = spawnSync(bash, [posix(path.join(directory, "deploy.sh"))], {
        encoding: "utf8",
        env: {
            ...process.env, BASH_ENV: posix(stub), FAKE_LOG: posix(log),
            FIREFOX_TTY: posix(path.join(directory, "tty")), FAKE_PROJECT: "firefox_custom",
            FAKE_VOLUMES: "", FAKE_CONTAINERS: "", FAKE_USERS: "", FAKE_BACKUP_FAIL: "0", ...fake,
        },
        timeout: 30000,
    });
    if (result.error) throw result.error;
    return { result, directory, calls: readFileSync(log, "utf8").split("\n").filter(Boolean) };
}

test("a fresh deploy creates the volume, backs it up offline and asks for the web password", () => {
    const { result, directory, calls } = deploy(undefined, { FAKE_USERS: "ERROR: Password database not found.\n" });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(readFileSync(path.join(directory, ".env"), "utf8"), /^FIREFOX_CONFIG_VOLUME=firefox_config$/m);
    assert.ok(calls.includes("volume create firefox_config"));
    assert.ok(calls.some(call => call.startsWith("run --rm --network none -v firefox_config:/data:ro")));
    assert.ok(calls.some(call => call.includes("--exclude=profile/cache2")));
    assert.ok(calls.indexOf("compose pull") < calls.indexOf("compose up -d --remove-orphans"));
    assert.ok(calls.includes("compose exec firefox webauth-user add alice"));
    assert.doesNotMatch(result.stdout, /不再使用/);
    assert.match(result.stdout, /部署完成/);
});

const legacy = "FIREFOX_CONFIG_VOLUME=\nWEB_AUTHENTICATION=1\nWEB_AUTHENTICATION_USERNAME=bob\n" +
    "WEB_AUTHENTICATION_PASSWORD='fixedREDACTEDvalue'\n";

test("deploying over a v1.1 install stops the old container and resets the fixed password", () => {
    const { result, directory, calls } = deploy(legacy, {
        FAKE_VOLUMES: "old_firefox_config\n", FAKE_CONTAINERS: "old1\nown1\n", FAKE_USERS: "bob\n",
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.doesNotMatch(result.stdout + result.stderr, /fixedREDACTEDvalue/);
    assert.match(result.stdout, /不再使用/);
    assert.ok(calls.includes("update --restart=no old1"));
    assert.ok(!calls.includes("update --restart=no own1"));
    assert.ok(calls.includes("stop -t 30 old1") && calls.includes("stop -t 30 own1"));
    assert.ok(calls.some(call => call.includes("-v old_firefox_config:/data:ro")));
    assert.ok(calls.includes("compose exec firefox webauth-user update bob"));
    assert.ok(!calls.some(call => call.includes("webauth-user add")));
    assert.ok(!calls.some(call => call.includes("webauth-user del")));
    const env = readFileSync(path.join(directory, ".env"), "utf8");
    assert.doesNotMatch(env, /WEB_AUTHENTICATION_(USERNAME|PASSWORD)/);
    assert.match(env, /^WEBAUTH_USER=bob$/m);
});

test("without a terminal the user with the published fixed password is deleted", () => {
    const { result, directory, calls } = deploy(legacy, {
        FAKE_VOLUMES: "firefox_config\n", FAKE_USERS: "bob\ncarol\n", FIREFOX_TTY: "/nonexistent/tty",
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.ok(calls.includes("compose exec -T firefox webauth-user del bob"));
    assert.ok(!calls.some(call => call.includes("webauth-user update")));
    assert.match(result.stdout, /已删除使用公开固定密码的用户 bob/);
    assert.doesNotMatch(readFileSync(path.join(directory, ".env"), "utf8"), /REDACTED/);
});

test("an unrelated user is never deleted because of a leftover legacy line", () => {
    const { result, calls } = deploy(legacy, {
        FAKE_VOLUMES: "firefox_config\n", FAKE_USERS: "carol\n", FIREFOX_TTY: "/nonexistent/tty",
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.ok(!calls.some(call => / webauth-user (del|update|add)/.test(call)));
});

test("stopped legacy containers lose their restart policy too, and only running ones are stopped", () => {
    const { result, calls } = deploy(undefined, {
        FAKE_VOLUMES: "firefox_config\n", FAKE_CONTAINERS: "old1\nold_off2\n",
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.ok(calls.includes("update --restart=no old1") && calls.includes("update --restart=no old_off2"));
    assert.ok(calls.includes("stop -t 30 old1"));
    assert.ok(!calls.includes("stop -t 30 old_off2"));
});

test("a failed backup restarts the stopped containers with their restart policy and deploys nothing", () => {
    const { result, directory, calls } = deploy(undefined, {
        FAKE_VOLUMES: "firefox_config\n", FAKE_CONTAINERS: "old1\n", FAKE_BACKUP_FAIL: "1",
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /备份失败/);
    assert.ok(calls.indexOf("update --restart=always old1") > calls.indexOf("update --restart=no old1"));
    assert.ok(calls.includes("start old1"));
    assert.ok(!calls.some(call => call.startsWith("compose up")));
    assert.deepEqual(readdirSync(path.join(directory, "backup")), []);
});
