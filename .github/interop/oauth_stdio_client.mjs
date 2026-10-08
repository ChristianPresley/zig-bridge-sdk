// The sign-in check of the URL form of the bridge. It uses the TypeScript SDK 1.x
// (@modelcontextprotocol/sdk, MCP revision 2025-11-25), like VS Code, and starts the bridge
// over stdio. The upstream server is bridge-fixture-server in its HTTPS mode, in its own
// process, with the certificate of the test CA. The check has two parts.
//
// The sign-in (bridge-fixture-server --https 0 --oauth):
//
// - starts the bridge with --no-browser, --token-store memory, --ca-file and a free
//   --redirect-port, as the process tests do, thus each run signs in again;
// - reads the sign-in line of the bridge from its stderr ("mcp-bridge-vscode: sign in at
//   <url>"), and asserts that the URL is a valid authorization URL of the fixture (https,
//   visible ASCII only, PKCE S256, the exact redirect URI and the MCP URL as the resource);
// - opens the URL as the browser of the user: it follows the redirects of the authorization
//   server, with the trust of the test CA only, into the loopback receiver of the bridge;
// - asserts that the negotiated protocol version is 2025-11-25, lists the tools and calls
//   the tool add;
// - calls the tool guarded, which needs one more scope. After notifications/initialized, the
//   bridge must ask the client with a URL elicitation (with an elicitationId) and write a new
//   sign-in line. The client accepts and opens the URL, as VS Code does. The check asserts
//   that notifications/elicitation/complete comes before the result, and that the next call
//   of guarded needs no new sign-in;
// - asserts that no code of a redirect is on stderr, and that each stderr line has the tag of
//   the bridge.
//
// The static authorization header (bridge-fixture-server --https 0 --bearer-env VAR): the
// fixture has no authorization server. The bridge gets the header with --header-env, and a
// marker header with --header. The check lists and calls the tools, and asserts that no
// sign-in line comes and that the token and the marker are not on stderr, also not in the
// debug lines. With a wrong token, initialize fails with
// -32603 and the HTTP status 401, and the bridge writes no sign-in line.
//
// After each part, the client closes the input of the bridge, and the check asserts that the
// bridge exits with code 0 before the transport stops it (2 s). The fixture server stops at
// the end of its stdin with code 0.
//
// It exits with code 1 on each failure.
//
// Usage: node oauth_stdio_client.mjs <bridge> <bridge-fixture-server> <test CA file>
// Example: node .github/interop/oauth_stdio_client.mjs zig-out/bin/mcp-bridge-vscode \
//            zig-out/bin/bridge-fixture-server test/fixtures/tls/ca.crt
//
// Install the pinned packages first: npm ci --ignore-scripts --prefix .github/interop
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import http from "node:http";
import https from "node:https";
import { createRequire } from "node:module";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
// The packages are in .github/interop/node_modules. createRequire resolves from the prefix of
// npm ci (see legacy_stdio_client.mjs).
const require = createRequire(path.join(here, "package.json"));
const { Client } = require("@modelcontextprotocol/sdk/client/index.js");
const { StdioClientTransport, getDefaultEnvironment } = require("@modelcontextprotocol/sdk/client/stdio.js");
const { LATEST_PROTOCOL_VERSION, ElicitRequestSchema, ElicitationCompleteNotificationSchema } = require("@modelcontextprotocol/sdk/types.js");

const expected_version = "2025-11-25";
// The time limit of the full check.
const overall_timeout_ms = 120_000;
// The time limit of the start of the fixture server and of its stop.
const fixture_timeout_ms = 15_000;
// StdioClientTransport.close() ends the input, waits 2 s for the exit, and then stops the
// process with SIGTERM.
const close_grace_ms = 2_000;
// The time limit of one request of the test browser.
const browse_timeout_ms = 10_000;
// The most redirects that the test browser follows.
const max_redirects = 5;
// The start of the sign-in line of the bridge on stderr.
const sign_in_prefix = "mcp-bridge-vscode: sign in at ";
// The start of each stderr line of the bridge.
const bridge_tag = "mcp-bridge-vscode: ";
// The scopes of the fixture (base_scope and step_up_scope of test/fixture_https.zig), the
// tool that needs the second scope and its text (guarded_tool and guarded_text of
// test/fixture.zig).
const base_scope = "mcp:read";
const step_up_scope = "mcp:write";
const guarded_tool = "guarded";
const guarded_text = "guarded: allowed";
// The environment variables of the static token: the fixture reads the token, and the bridge
// reads the full header value.
const fixture_token_variable = "BRIDGE_FIXTURE_INTEROP_TOKEN";
const header_variable = "MCP_BRIDGE_INTEROP_AUTH";

const failures = [];
function fail(message) {
  failures.push(message);
  console.error(`FAIL: ${message}`);
}
function ok(message) {
  console.log(`ok: ${message}`);
}

// On Windows, a path without an extension gets ".exe" when that file exists. Thus the same
// command line works on each system.
function executable(file) {
  if (process.platform === "win32" && path.extname(file) === "" && existsSync(`${file}.exe`)) return `${file}.exe`;
  return file;
}

const [bridge_arg, fixture_arg, ca_file] = process.argv.slice(2);
if (!bridge_arg || !fixture_arg || !ca_file) {
  console.error("Usage: node oauth_stdio_client.mjs <bridge> <bridge-fixture-server> <test CA file>");
  process.exit(2);
}
const bridge_path = executable(bridge_arg);
const fixture_path = executable(fixture_arg);
const ca = readFileSync(ca_file);

const watchdog = setTimeout(() => {
  console.error(`FAIL: the check did not finish in ${overall_timeout_ms} ms`);
  process.exit(1);
}, overall_timeout_ms);
watchdog.unref();

// The 1.x Client has no getter for the negotiated version. After initialize, it gives the
// version to transport.setProtocolVersion, which only the HTTP transports have. The transport
// also keeps its private ChildProcess only until close(), thus `exited` takes the exit of
// the process at the start.
class RecordingTransport extends StdioClientTransport {
  async start() {
    await super.start();
    const child = this._process;
    this.exited = new Promise((resolve) => {
      if (!child) return resolve(undefined);
      if (child.exitCode !== null || child.signalCode !== null) return resolve({ code: child.exitCode, signal: child.signalCode });
      child.once("exit", (code, signal) => resolve({ code, signal }));
    });
  }

  setProtocolVersion(version) {
    this.protocolVersion = version;
  }
}

// The environment of a child process. The SDK gives a short list of variables. On Windows,
// that list has no PATHEXT. The list has no proxy variable and no secret of the bridge.
function childEnvironment(extra) {
  const env = { ...getDefaultEnvironment(), ...extra };
  if (process.platform === "win32" && process.env.PATHEXT) env.PATHEXT = process.env.PATHEXT;
  return env;
}

// A free port on 127.0.0.1 for the redirect URI.
function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

// Start bridge-fixture-server --https 0 with `args`, and read the URL of its MCP endpoint
// from the first line of its stdout. The server stops at the end of its stdin.
async function startFixture(args, extra_env) {
  const child = spawn(fixture_path, ["--https", "0", ...args], { stdio: ["pipe", "pipe", "inherit"], env: childEnvironment(extra_env) });
  const exited = new Promise((resolve) => child.once("exit", (code, signal) => resolve({ code, signal })));
  const url = await new Promise((resolve, reject) => {
    let text = "";
    const timer = setTimeout(() => reject(new Error(`bridge-fixture-server ${args.join(" ")} wrote no URL in ${fixture_timeout_ms} ms`)), fixture_timeout_ms);
    child.once("error", reject);
    exited.then(({ code }) => reject(new Error(`bridge-fixture-server ${args.join(" ")} exited with code ${code} before its URL`)));
    child.stdout.on("data", (chunk) => {
      text += chunk.toString("utf8");
      const nl = text.indexOf("\n");
      if (nl !== -1) {
        clearTimeout(timer);
        resolve(text.slice(0, nl).trim());
      }
    });
  });
  return {
    url,
    async stop() {
      child.stdin.end();
      const timer = setTimeout(() => child.kill(), fixture_timeout_ms);
      const exit = await exited;
      clearTimeout(timer);
      if (exit.code === 0) {
        ok(`bridge-fixture-server ${args.join(" ")} exited with code 0 at the end of its input`);
      } else {
        fail(`bridge-fixture-server ${args.join(" ")} exited with code ${exit.code} and signal ${exit.signal}`);
      }
    },
  };
}

function isLoopback(host) {
  return host === "localhost" || host === "[::1]" || /^127\.\d+\.\d+\.\d+$/.test(host);
}

// One GET request. An https URL needs a certificate of the test CA only.
function get(url) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const secure = target.protocol === "https:";
    const options = { method: "GET", headers: { accept: "text/html" }, agent: false };
    if (secure) options.ca = ca;
    const request = (secure ? https : http).request(target, options, (response) => {
      response.resume();
      response.on("end", () => resolve({ status: response.statusCode, location: response.headers.location }));
      response.on("error", reject);
    });
    request.setTimeout(browse_timeout_ms, () => request.destroy(new Error(`no response from ${target.origin} in ${browse_timeout_ms} ms`)));
    request.on("error", reject);
    request.end();
  });
}

// Open `url` as the browser of the user: GET each URL and follow each redirect. An http URL
// must have a loopback host, for example the redirect URI of the sign-in. Returns the status
// and the URL of the last response.
async function browse(url) {
  let current = url;
  for (let redirects = 0; ; redirects += 1) {
    const target = new URL(current);
    if (target.protocol !== "https:" && !(target.protocol === "http:" && isLoopback(target.hostname))) {
      throw new Error(`the browser does not open ${target.protocol}//${target.host}`);
    }
    const response = await get(current);
    if (response.status < 300 || response.status >= 400) return { status: response.status, url: current };
    if (redirects === max_redirects) throw new Error(`more than ${max_redirects} redirects`);
    if (typeof response.location !== "string" || !/^https?:\/\//i.test(response.location)) {
      throw new Error(`a redirect without an absolute Location: ${JSON.stringify(response.location)}`);
    }
    current = response.location;
  }
}

// Open the URL of a sign-in, and return the code of the redirect to the bridge, or undefined
// after a failure. The authorization server of the fixture approves each request.
async function approve(url, redirect_uri, what) {
  let visit;
  try {
    visit = await browse(url);
  } catch (err) {
    fail(`${what}: the browser failed: ${err?.message ?? err}`);
    return undefined;
  }
  const code = new URL(visit.url).searchParams.get("code");
  if (visit.status !== 200 || !visit.url.startsWith(`${redirect_uri}?`) || !code) {
    fail(`${what}: the browser ended at ${visit.url} with the status ${visit.status}, not at the redirect URI with a code`);
    return undefined;
  }
  ok(`${what}: the redirect with a code reached the bridge (status 200)`);
  return code;
}

// Check an authorization URL of the bridge as P1 of the plan says, and return its scopes.
function checkSignInUrl(url, fixture_url, redirect_uri, what) {
  const problems = [];
  if (url.length > 8192) problems.push("it has more than 8 KiB");
  if (!/^[\x21-\x7e]+$/.test(url)) problems.push("it has a character that is not visible ASCII");
  if (/["<>\\^`{|}]/.test(url)) problems.push("it has a character that a shell or a browser can change");
  if (/%(?![0-9A-Fa-f]{2})/.test(url)) problems.push("it has a % that does not start a %XX escape");
  let target;
  try {
    target = new URL(url);
  } catch {
    fail(`${what}: the sign-in URL is not a URL: ${url}`);
    return "";
  }
  const origin = new URL(fixture_url).origin;
  if (target.protocol !== "https:") problems.push("it does not use https");
  if (target.origin !== origin) problems.push(`its origin is not ${origin}`);
  if (target.username !== "" || target.password !== "") problems.push("it has a user or a password");
  if (url.includes("#")) problems.push("it has a fragment");
  const query = target.searchParams;
  const expected = { response_type: "code", code_challenge_method: "S256", redirect_uri, resource: fixture_url };
  for (const [name, value] of Object.entries(expected)) {
    if (query.get(name) !== value) problems.push(`${name} is ${JSON.stringify(query.get(name))}, not ${JSON.stringify(value)}`);
  }
  for (const name of ["client_id", "state", "code_challenge"]) {
    if (!query.get(name)) problems.push(`it has no ${name}`);
  }
  if (problems.length === 0) {
    ok(`${what}: the sign-in URL is a valid authorization URL of the fixture`);
  } else {
    fail(`${what}: the sign-in URL is not valid: ${problems.join("; ")}: ${url}`);
  }
  return query.get("scope") ?? "";
}

// Make the transport and the client for the bridge with `args` and the extra environment
// `extra_env`. The caller adds its handlers, and then calls connect(session), which starts the
// bridge. The session records the stdout messages, the stderr lines and the sign-in URLs.
// Before the end of initialize, `on_sign_in(url)` gets each sign-in URL.
function startBridge(args, extra_env, on_sign_in) {
  const transport = new RecordingTransport({ command: bridge_path, args, env: childEnvironment(extra_env), stderr: "pipe" });
  const session = { transport, frames: [], lines: [], sign_ins: [], initialized: false, stderr_text: "" };
  // Each message from the bridge. Client.connect keeps this handler and calls it first.
  transport.onmessage = (message) => session.frames.push(message);
  // The transport gives the stderr stream before the start. The check writes each line of the
  // bridge to its own stderr, as the Output channel of VS Code shows it.
  let partial = "";
  transport.stderr.on("data", (chunk) => {
    const text = chunk.toString("utf8");
    session.stderr_text += text;
    partial += text;
    let nl;
    while ((nl = partial.indexOf("\n")) !== -1) {
      const line = partial.slice(0, nl).replace(/\r$/, "");
      partial = partial.slice(nl + 1);
      session.lines.push(line);
      process.stderr.write(`[bridge] ${line}\n`);
      if (line.startsWith(sign_in_prefix)) {
        const url = line.slice(sign_in_prefix.length);
        session.sign_ins.push(url);
        if (!session.initialized && on_sign_in) on_sign_in(url);
      }
    }
  });
  session.client = new Client({ name: "zig-bridge-sdk-interop", version: "0.0.0" }, { capabilities: { elicitation: { form: {}, url: {} } } });
  session.client.onerror = (err) => fail(`transport or protocol error: ${err?.message ?? err}`);
  return session;
}

// Connect, and record the exit of the bridge. Returns the error of initialize, or undefined.
async function connect(session) {
  try {
    await session.client.connect(session.transport);
  } catch (err) {
    return err;
  } finally {
    session.initialized = true;
    session.exited = session.transport.exited ?? Promise.resolve(undefined);
  }
  if (session.transport.protocolVersion === expected_version) {
    ok(`negotiated protocol version ${session.transport.protocolVersion}`);
  } else {
    fail(`negotiated protocol version ${JSON.stringify(session.transport.protocolVersion)}, expected ${expected_version}`);
  }
  return undefined;
}

// Close the input of the bridge, and assert that it exits with code 0 before the transport
// stops it.
async function closeBridge(session, what) {
  const start = Date.now();
  await session.client.close().catch(() => {});
  const exit = await session.exited;
  const elapsed = Date.now() - start;
  if (!exit) {
    fail(`${what}: the transport has no process: the exit check needs the pinned SDK 1.32.1`);
  } else if (exit.code === 0 && elapsed < close_grace_ms) {
    ok(`${what}: the bridge exited with code 0 ${elapsed} ms after the end of its input`);
  } else {
    fail(`${what}: after the end of its input, the bridge exited with code ${exit.code} and signal ${exit.signal} after ${elapsed} ms`);
  }
}

// Each stderr line must have the tag of the bridge. No other process writes to this stderr.
function checkTags(session, what) {
  const bad = session.lines.filter((line) => !line.startsWith(bridge_tag));
  if (bad.length === 0) {
    ok(`${what}: each of the ${session.lines.length} stderr lines has the tag of the bridge`);
  } else {
    fail(`${what}: stderr lines without the tag of the bridge: ${JSON.stringify(bad)}`);
  }
}

function checkNotOnStderr(session, secret, name, what) {
  if (session.stderr_text.includes(secret)) {
    fail(`${what}: stderr has ${name}`);
  } else {
    ok(`${what}: stderr does not have ${name}`);
  }
}

async function callText(client, name, args) {
  try {
    const result = await client.callTool({ name, arguments: args });
    if (result.isError) {
      fail(`tools/call ${name}: isError is true: ${JSON.stringify(result.content)}`);
      return undefined;
    }
    return (result.content ?? []).filter((block) => block.type === "text").map((block) => block.text).join("");
  } catch (err) {
    fail(`tools/call ${name}: ${err?.message ?? err}`);
    return undefined;
  }
}

async function expectText(client, name, args, expected) {
  const text = await callText(client, name, args);
  if (text === undefined) return;
  if (text === expected) {
    ok(`tools/call ${name} -> ${JSON.stringify(text)}`);
  } else {
    fail(`tools/call ${name}: expected the text ${JSON.stringify(expected)}, got ${JSON.stringify(text)}`);
  }
}

async function expectTools(client, names, what) {
  try {
    const tools = new Set();
    let cursor;
    do {
      const page = await client.listTools(cursor === undefined ? {} : { cursor });
      for (const tool of page.tools) tools.add(tool.name);
      cursor = typeof page.nextCursor === "string" ? page.nextCursor : undefined;
    } while (cursor !== undefined);
    const missing = names.filter((name) => !tools.has(name));
    if (missing.length === 0) {
      ok(`${what}: tools/list has ${names.join(", ")} (${tools.size} tools)`);
    } else {
      fail(`${what}: tools/list does not have ${missing.join(", ")}`);
    }
  } catch (err) {
    fail(`${what}: tools/list: ${err?.message ?? err}`);
  }
}

async function checkSignIn() {
  const what = "sign-in";
  const fixture = await startFixture(["--oauth"], {});
  const port = await freePort();
  const redirect_uri = `http://127.0.0.1:${port}/callback`;
  const visits = [];
  const session = startBridge(
    ["--no-browser", "--token-store", "memory", "--ca-file", ca_file, "--redirect-port", String(port), "--log-level", "debug", fixture.url],
    {},
    // The sign-in before notifications/initialized: the user opens the URL of the line.
    (url) => visits.push(approve(url, redirect_uri, "the first sign-in")),
  );
  // After notifications/initialized, a sign-in comes as a URL elicitation. VS Code shows the
  // URL, and opens it after the user accepts.
  const elicitations = [];
  const completed = [];
  session.client.setRequestHandler(ElicitRequestSchema, async (request) => {
    const params = request.params;
    if (params.mode !== "url") {
      fail(`a form elicitation came: ${JSON.stringify(params)}`);
      return { action: "decline" };
    }
    elicitations.push(params);
    setImmediate(() => visits.push(approve(params.url, redirect_uri, "the step-up sign-in")));
    return { action: "accept" };
  });
  session.client.setNotificationHandler(ElicitationCompleteNotificationSchema, (notification) => {
    completed.push(notification.params.elicitationId);
  });

  try {
    const error = await connect(session);
    if (error) {
      fail(`${what}: initialize: ${error?.message ?? error}`);
      return;
    }
    const first_code = await visits[0];
    if (session.sign_ins.length === 1) {
      ok(`${what}: one sign-in line came before the end of initialize`);
      const scope = checkSignInUrl(session.sign_ins[0], fixture.url, redirect_uri, "the first sign-in");
      if (!scope.split(" ").includes(base_scope) || scope.split(" ").includes(step_up_scope)) fail(`the first sign-in asks for the scopes ${JSON.stringify(scope)}`);
    } else {
      fail(`${what}: ${session.sign_ins.length} sign-in lines came before the end of initialize, not 1`);
    }

    await expectTools(session.client, ["add", guarded_tool], what);
    await expectText(session.client, "add", { a: 2, b: 3 }, "5");

    // The step-up. The completion of the elicitation comes before the result.
    const from = session.frames.length;
    await expectText(session.client, guarded_tool, {}, guarded_text);
    const after = session.frames.slice(from);
    const response = after.findIndex((m) => "id" in m && !("method" in m) && m.id !== undefined && ("result" in m || "error" in m));
    const second_code = await visits[1];
    if (elicitations.length !== 1) {
      fail(`the step-up: ${elicitations.length} URL elicitations, not 1`);
    } else {
      const params = elicitations[0];
      if (typeof params.elicitationId !== "string" || params.elicitationId === "") fail("the step-up: the URL elicitation has no elicitationId");
      if (session.sign_ins.length === 2 && session.sign_ins[1] === params.url) {
        ok("the step-up: the URL elicitation has the URL of the second sign-in line");
      } else {
        fail(`the step-up: the URL of the elicitation is not the second sign-in line: ${JSON.stringify(session.sign_ins)}`);
      }
      const scope = checkSignInUrl(params.url, fixture.url, redirect_uri, "the step-up sign-in");
      if (!scope.split(" ").includes(step_up_scope)) fail(`the step-up asks for the scopes ${JSON.stringify(scope)}, without ${step_up_scope}`);
      const complete = after.findIndex((m) => m.method === "notifications/elicitation/complete" && m.params?.elicitationId === params.elicitationId);
      if (complete !== -1 && response !== -1 && complete < response && completed.length === 1 && completed[0] === params.elicitationId) {
        ok("the step-up: notifications/elicitation/complete came before the result");
      } else {
        fail(`the step-up: no notifications/elicitation/complete for ${params.elicitationId} before the result: ${JSON.stringify(after.map((m) => m.method ?? m.id))}`);
      }
    }

    // The token has the scope now: no new sign-in.
    await expectText(session.client, guarded_tool, {}, guarded_text);
    if (elicitations.length === 1 && session.sign_ins.length === 2) {
      ok("the second call of guarded needs no new sign-in");
    } else {
      fail(`after the second call of guarded: ${elicitations.length} URL elicitations and ${session.sign_ins.length} sign-in lines`);
    }

    await closeBridge(session, what);
    for (const [code, name] of [
      [first_code, "the code of the first redirect"],
      [second_code, "the code of the step-up redirect"],
    ]) {
      if (code) checkNotOnStderr(session, code, name, what);
    }
    checkTags(session, what);
  } finally {
    await session.client.close().catch(() => {});
    await fixture.stop();
  }
}

async function checkStaticHeader() {
  const what = "static header";
  const token = `interop-marker-${randomBytes(12).toString("hex")}`;
  // A value of --header is on the command line. It is not a secret, but the bridge never
  // writes a header value to stderr.
  const trace = `interop-marker-${randomBytes(12).toString("hex")}`;
  const fixture = await startFixture(["--bearer-env", fixture_token_variable], { [fixture_token_variable]: token });
  try {
    // The debug lines have each upstream request. They must not have a header value.
    const args = ["--log-level", "debug", "--header-env", `Authorization=${header_variable}`, "--header", `X-Trace:${trace}`, "--ca-file", ca_file, fixture.url];
    const session = startBridge(args, { [header_variable]: `Bearer ${token}` }, undefined);
    try {
      const error = await connect(session);
      if (error) {
        fail(`${what}: initialize: ${error?.message ?? error}`);
      } else {
        await expectTools(session.client, ["add", guarded_tool], what);
        await expectText(session.client, "add", { a: 2, b: 3 }, "5");
        await expectText(session.client, "echo", { text: "static header" }, "static header");
        await closeBridge(session, what);
        if (session.sign_ins.length === 0) {
          ok(`${what}: no sign-in line`);
        } else {
          fail(`${what}: ${session.sign_ins.length} sign-in lines`);
        }
        checkNotOnStderr(session, token, "the token of the header", what);
        checkNotOnStderr(session, trace, "the value of --header", what);
        checkTags(session, what);
      }
    } finally {
      await session.client.close().catch(() => {});
    }

    // A wrong token: the fixture answers 401 with no authorization server. The bridge does no
    // sign-in, because a static authorization header excludes it.
    const wrong = `interop-marker-${randomBytes(12).toString("hex")}`;
    const refused = startBridge(args, { [header_variable]: `Bearer ${wrong}` }, undefined);
    try {
      const error = await connect(refused);
      const detail = String(error?.data?.detail ?? "");
      if (error && error.code === -32603 && detail.includes("HTTP status 401")) {
        ok(`${what}: a wrong token fails initialize with -32603 (${detail})`);
      } else {
        fail(`${what}: a wrong token: initialize gave ${error ? `${error.code} ${error.message} ${JSON.stringify(error.data)}` : "a result"}, not -32603 with the HTTP status 401`);
      }
      // Client.connect closes the transport after a failed initialize.
      const exit = await refused.exited;
      if (exit && exit.code === 0) {
        ok(`${what}: the bridge exited with code 0 after the failed initialize`);
      } else {
        fail(`${what}: after the failed initialize, the bridge exited with ${JSON.stringify(exit)}`);
      }
      if (refused.sign_ins.length !== 0) fail(`${what}: a wrong token gave ${refused.sign_ins.length} sign-in lines`);
      checkNotOnStderr(refused, wrong, "the wrong token", what);
    } finally {
      await refused.client.close().catch(() => {});
    }
  } finally {
    await fixture.stop();
  }
}

async function main() {
  if (LATEST_PROTOCOL_VERSION !== expected_version) {
    fail(`the SDK sends the protocol version ${LATEST_PROTOCOL_VERSION}, not ${expected_version}: pin a 1.x release that sends ${expected_version}`);
  }
  await checkSignIn();
  await checkStaticHeader();
}

try {
  await main();
} catch (err) {
  fail(`unexpected error: ${err?.stack ?? err}`);
}
if (failures.length > 0) {
  console.error(`${failures.length} failure(s)`);
  process.exit(1);
}
console.log("all checks passed");
process.exit(0);
