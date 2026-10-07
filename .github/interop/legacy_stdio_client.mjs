// A legacy MCP client for the interop check of the bridge. It uses the TypeScript SDK 1.x
// (@modelcontextprotocol/sdk, MCP revision 2025-11-25), like VS Code, and starts the bridge
// over stdio with the given command. Then it:
//
// - connects, and asserts that the negotiated protocol version is 2025-11-25;
// - lists the tools page by page, and asserts that no page has a nextCursor that is not a
//   string (VS Code asks for the next page while nextCursor is not undefined);
// - asserts that each inputSchema passes the two schema checks of VS Code: the draft-07 meta
//   schema of Ajv after the root gets `properties: {}` (the workbench), and no node with
//   `type: "array"` and a falsy `items` (the Copilot extension);
// - calls the tools add, echo and bare_array of bridge-fixture-server;
// - closes the input of the bridge, and asserts that the bridge exits with code 0 before the
//   transport stops it (2 s).
//
// It exits with code 1 on each failure.
//
// Usage: node legacy_stdio_client.mjs <bridge> [bridge arguments...]
// Example: node .github/interop/legacy_stdio_client.mjs zig-out/bin/mcp-bridge-vscode -- \
//            zig-out/bin/bridge-fixture-server --many-tools 150
//
// Install the pinned packages first: npm ci --ignore-scripts --prefix .github/interop
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
// The packages are in .github/interop/node_modules. A bare ESM import resolves from the
// directory of the script and its parents, thus it does not find them from another
// working directory. createRequire resolves from the prefix of npm ci.
const require = createRequire(path.join(here, "package.json"));
const { Client } = require("@modelcontextprotocol/sdk/client/index.js");
const { StdioClientTransport, getDefaultEnvironment } = require("@modelcontextprotocol/sdk/client/stdio.js");
const { LATEST_PROTOCOL_VERSION } = require("@modelcontextprotocol/sdk/types.js");
const ajvModule = require("ajv");
const Ajv = ajvModule.default ?? ajvModule;

const expected_version = "2025-11-25";
// A stop for a bridge that sends the same cursor again and again.
const max_pages = 1000;
// The time limit of the full check.
const overall_timeout_ms = 120_000;
// StdioClientTransport.close() ends the input, waits 2 s for the exit, and then stops the
// process with SIGTERM.
const close_grace_ms = 2_000;

const failures = [];
function fail(message) {
  failures.push(message);
  console.error(`FAIL: ${message}`);
}
function ok(message) {
  console.log(`ok: ${message}`);
}

const [command, ...args] = process.argv.slice(2);
if (!command) {
  console.error("Usage: node legacy_stdio_client.mjs <bridge> [bridge arguments...]");
  process.exit(2);
}

const watchdog = setTimeout(() => {
  console.error(`FAIL: the check did not finish in ${overall_timeout_ms} ms`);
  process.exit(1);
}, overall_timeout_ms);
watchdog.unref();

// The 1.x Client has no getter for the negotiated version. After initialize, it gives the
// version to transport.setProtocolVersion, which only the HTTP transports have.
class RecordingTransport extends StdioClientTransport {
  setProtocolVersion(version) {
    this.protocolVersion = version;
  }
}

// Each node with `type: "array"` and a falsy `items`, as the schema normalizer of the
// Copilot extension finds them (it throws on each of them). The walk examines the schema
// keywords only, not data such as `default`, `const`, `enum` or `examples`.
const schema_keywords = ["additionalProperties", "not", "if", "then", "else", "contains"];
const schema_map_keywords = ["properties", "patternProperties", "dependencies", "dependentSchemas", "$defs", "definitions"];
const schema_array_keywords = ["anyOf", "allOf", "oneOf", "prefixItems"];

function arraysWithoutItems(node, pointer, out, depth = 0) {
  if (node === null || typeof node !== "object" || Array.isArray(node) || depth > 64) return out;
  if (node.type === "array" && !node.items) out.push(pointer || "/");
  for (const key of schema_keywords) {
    if (key in node) arraysWithoutItems(node[key], `${pointer}/${key}`, out, depth + 1);
  }
  for (const key of schema_map_keywords) {
    const map = node[key];
    if (map && typeof map === "object" && !Array.isArray(map)) {
      for (const [name, child] of Object.entries(map)) {
        arraysWithoutItems(child, `${pointer}/${key}/${name}`, out, depth + 1);
      }
    }
  }
  for (const key of [...schema_array_keywords, "items"]) {
    const list = node[key];
    if (Array.isArray(list)) {
      list.forEach((child, i) => arraysWithoutItems(child, `${pointer}/${key}/${i}`, out, depth + 1));
    } else if (key === "items") {
      arraysWithoutItems(list, `${pointer}/items`, out, depth + 1);
    }
  }
  return out;
}

function textOf(result) {
  if (!Array.isArray(result.content)) return undefined;
  return result.content.filter((block) => block.type === "text").map((block) => block.text).join("");
}

async function callAndExpect(client, name, args, expected) {
  try {
    const result = await client.callTool({ name, arguments: args });
    if (!Array.isArray(result.content)) {
      fail(`tools/call ${name}: the result has no content array`);
      return;
    }
    if (result.isError) {
      fail(`tools/call ${name}: isError is true: ${JSON.stringify(result.content)}`);
      return;
    }
    const text = textOf(result);
    if (text !== expected) {
      fail(`tools/call ${name}: expected the text ${JSON.stringify(expected)}, got ${JSON.stringify(text)}`);
      return;
    }
    ok(`tools/call ${name} -> ${JSON.stringify(text)}`);
  } catch (err) {
    fail(`tools/call ${name}: ${err?.message ?? err}`);
  }
}

async function main() {
  if (LATEST_PROTOCOL_VERSION !== expected_version) {
    fail(`the SDK sends the protocol version ${LATEST_PROTOCOL_VERSION}, not ${expected_version}: pin a 1.x release that sends ${expected_version}`);
  }

  // The SDK gives the bridge a short list of environment variables. On Windows that list has
  // no PATHEXT, and without PATHEXT the bridge cannot start an upstream command that has no
  // extension. VS Code gives the bridge its full environment.
  const env = { ...getDefaultEnvironment() };
  if (process.platform === "win32" && process.env.PATHEXT) env.PATHEXT = process.env.PATHEXT;
  const transport = new RecordingTransport({ command, args, env, stderr: "inherit" });
  const client = new Client({ name: "zig-bridge-sdk-interop", version: "0.0.0" }, { capabilities: {} });
  // A stdout line that is not one JSON-RPC message, or a response with an unknown id, comes
  // here.
  client.onerror = (err) => fail(`transport or protocol error: ${err?.message ?? err}`);

  try {
    await client.connect(transport);
  } catch (err) {
    fail(`initialize: ${err?.message ?? err}`);
    await client.close().catch(() => {});
    return;
  }
  if (transport.protocolVersion === expected_version) {
    ok(`negotiated protocol version ${transport.protocolVersion}`);
  } else {
    fail(`negotiated protocol version ${JSON.stringify(transport.protocolVersion)}, expected ${expected_version}`);
  }
  const info = client.getServerVersion();
  if (info && typeof info.name === "string" && info.name !== "" && typeof info.version === "string") {
    ok(`serverInfo ${info.name} ${info.version}`);
  } else {
    fail(`serverInfo is not usable: ${JSON.stringify(info)}`);
  }
  // Without capabilities.tools, VS Code never sends tools/list.
  if (client.getServerCapabilities()?.tools) {
    ok("capabilities.tools is present");
  } else {
    fail(`capabilities.tools is missing: ${JSON.stringify(client.getServerCapabilities())}`);
  }

  // The private ChildProcess of the pinned transport. The exit code is not available
  // otherwise.
  const child = transport._process;
  const exited = new Promise((resolve) => {
    if (!child) return resolve(undefined);
    if (child.exitCode !== null || child.signalCode !== null) {
      return resolve({ code: child.exitCode, signal: child.signalCode });
    }
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
  if (!child) fail("the transport has no _process: the exit check needs the pinned SDK 1.32.1");

  const tools = [];
  let pages = 0;
  const before_list = failures.length;
  try {
    let cursor;
    do {
      // VS Code sends {} on the first page and {cursor} on the next pages.
      const page = await client.listTools(cursor === undefined ? {} : { cursor });
      pages += 1;
      if ("nextCursor" in page && typeof page.nextCursor !== "string") {
        fail(`tools/list page ${pages}: nextCursor is ${JSON.stringify(page.nextCursor)}, not a string`);
        cursor = undefined;
        break;
      }
      tools.push(...page.tools);
      cursor = page.nextCursor;
    } while (cursor !== undefined && pages < max_pages);
    if (cursor !== undefined) fail(`tools/list: more than ${max_pages} pages`);
  } catch (err) {
    fail(`tools/list page ${pages + 1}: ${err?.message ?? err}`);
  }
  if (failures.length === before_list) ok(`tools/list: ${tools.length} tools on ${pages} page(s)`);

  const names = new Set();
  for (const tool of tools) {
    if (names.has(tool.name)) fail(`tools/list: the tool ${tool.name} occurs two times`);
    names.add(tool.name);
  }
  for (const name of ["add", "echo", "bare_array"]) {
    if (!names.has(name)) fail(`tools/list: the tool ${name} is missing`);
  }

  // The workbench of VS Code adds properties: {} to the root and validates the schema
  // against draft-07.
  const ajv = new Ajv();
  let draft07 = 0;
  let copilot = 0;
  for (const tool of tools) {
    const schema = { ...tool.inputSchema };
    schema.properties ??= {};
    try {
      if (ajv.validateSchema(schema)) {
        draft07 += 1;
      } else {
        fail(`tool ${tool.name}: the inputSchema is not a draft-07 schema: ${ajv.errorsText(ajv.errors)}`);
      }
    } catch (err) {
      fail(`tool ${tool.name}: Ajv cannot examine the inputSchema: ${err?.message ?? err}`);
    }
    const bad = arraysWithoutItems(tool.inputSchema, "", []);
    if (bad.length === 0) {
      copilot += 1;
    } else {
      fail(`tool ${tool.name}: array schemas without items at ${bad.join(", ")}`);
    }
  }
  if (draft07 === tools.length) ok(`${tools.length} inputSchemas pass the draft-07 meta schema of Ajv`);
  if (copilot === tools.length) ok(`${tools.length} inputSchemas have items in each array schema`);

  await callAndExpect(client, "add", { a: 2, b: 3 }, "5");
  await callAndExpect(client, "echo", { text: "legacy client" }, "legacy client");
  await callAndExpect(client, "bare_array", { values: [1, "x", null], pair: ["a", 2] }, "3 values");

  const start = Date.now();
  await client.close();
  const exit = await exited;
  const elapsed = Date.now() - start;
  if (exit) {
    if (exit.code === 0 && elapsed < close_grace_ms) {
      ok(`the bridge exited with code 0 ${elapsed} ms after the end of its input`);
    } else {
      fail(`after the end of its input, the bridge exited with code ${exit.code} and signal ${exit.signal} after ${elapsed} ms`);
    }
  }
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
