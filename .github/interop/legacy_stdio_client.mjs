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
// - declares elicitation (form and url), sampling and roots, as VS Code does, and answers the
//   requests of the bridge: a form gets accept with a value for each property, a URL gets
//   accept, sampling gets a text of the model, and roots/list gets one file root;
// - calls the tools ask_form, ask_url, ask_url_twice, ask_bad_url, sample, list_roots and multi
//   and the prompt ask_name, which ask for input, and asserts their results;
// - asserts that each URL elicitation has an elicitationId, that the client gets one
//   notifications/elicitation/complete for each of them, and that the file URL of ask_bad_url
//   never comes to the client;
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
import { fileURLToPath, pathToFileURL } from "node:url";
import { isDeepStrictEqual } from "node:util";

const here = path.dirname(fileURLToPath(import.meta.url));
// The packages are in .github/interop/node_modules. A bare ESM import resolves from the
// directory of the script and its parents, thus it does not find them from another
// working directory. createRequire resolves from the prefix of npm ci.
const require = createRequire(path.join(here, "package.json"));
const { Client } = require("@modelcontextprotocol/sdk/client/index.js");
const { StdioClientTransport, getDefaultEnvironment } = require("@modelcontextprotocol/sdk/client/stdio.js");
const {
  LATEST_PROTOCOL_VERSION,
  ElicitRequestSchema,
  CreateMessageRequestSchema,
  ListRootsRequestSchema,
} = require("@modelcontextprotocol/sdk/types.js");
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

// Call the tool `name` and return the text of its result, or undefined after a failure.
async function callText(client, name, args) {
  try {
    const result = await client.callTool({ name, arguments: args });
    if (!Array.isArray(result.content)) {
      fail(`tools/call ${name}: the result has no content array`);
      return undefined;
    }
    if (result.isError) {
      fail(`tools/call ${name}: isError is true: ${JSON.stringify(result.content)}`);
      return undefined;
    }
    return textOf(result);
  } catch (err) {
    fail(`tools/call ${name}: ${err?.message ?? err}`);
    return undefined;
  }
}

async function callAndExpect(client, name, args, expected) {
  const text = await callText(client, name, args);
  if (text === undefined) return;
  if (text !== expected) {
    fail(`tools/call ${name}: expected the text ${JSON.stringify(expected)}, got ${JSON.stringify(text)}`);
    return;
  }
  ok(`tools/call ${name} -> ${JSON.stringify(text)}`);
}

// The capabilities of VS Code for input requests. VS Code also declares roots.listChanged and
// tasks, which this check does not use.
const input_capabilities = { elicitation: { form: {}, url: {} }, sampling: {}, roots: {} };
// The root of the client. Only file URIs go to the upstream server.
const root_uri = pathToFileURL(process.cwd()).href;
// The answer of the model to each sampling request.
const model_answer = { model: "interop", role: "assistant", content: { type: "text", text: "hello" } };
// The content that the answer to the form of ask_form has (see formContent).
const profile_answer = { name: "Ada", age: 36, subscribe: true, color: "red" };

// The content of an accepted form: a value for each property of the requested schema. The
// first choice of an enum, "Ada" for a string, 36 for a number and true for a boolean. These
// values are valid for the forms of bridge-fixture-server and for the Continue form of the
// bridge.
function formContent(requestedSchema) {
  const content = {};
  for (const [name, property] of Object.entries(requestedSchema?.properties ?? {})) {
    if (Array.isArray(property.enum) && property.enum.length > 0) {
      content[name] = property.enum[0];
    } else if (Array.isArray(property.oneOf) && property.oneOf.length > 0) {
      content[name] = property.oneOf[0].const;
    } else if (property.type === "string") {
      content[name] = "Ada";
    } else if (property.type === "integer" || property.type === "number") {
      content[name] = 36;
    } else if (property.type === "boolean") {
      content[name] = true;
    }
  }
  return content;
}

// Answer the requests of the bridge as a user of VS Code who accepts each request. The SDK
// validates each request and each answer against its schemas of revision 2025-11-25.
function addInputHandlers(client) {
  client.setRequestHandler(ElicitRequestSchema, async (request) => {
    const params = request.params;
    if (params.mode === "url") {
      if (typeof params.elicitationId !== "string" || params.elicitationId === "") {
        fail(`elicitation/create for ${params.url}: the URL elicitation has no elicitationId`);
      }
      return { action: "accept" };
    }
    return { action: "accept", content: formContent(params.requestedSchema) };
  });
  client.setRequestHandler(CreateMessageRequestSchema, async () => model_answer);
  client.setRequestHandler(ListRootsRequestSchema, async () => ({ roots: [{ uri: root_uri, name: "interop" }] }));
}

// Check the requests and notifications of the bridge for the input requests. `frames` holds
// each message from the bridge in the order of arrival.
function checkInputFrames(frames) {
  const url_elicitations = frames.filter((m) => m.method === "elicitation/create" && "id" in m && m.params?.mode === "url");
  const ids = [];
  for (const m of url_elicitations) {
    const id = m.params.elicitationId;
    if (typeof id !== "string" || id === "") {
      fail(`the URL elicitation ${JSON.stringify(m.id)} for ${m.params.url} has no elicitationId`);
    } else {
      ids.push(id);
    }
  }
  // ask_url and the first round of ask_url_twice. The second round of ask_url_twice is a form.
  if (url_elicitations.length !== 2) {
    fail(`expected 2 URL elicitations, got ${url_elicitations.length}`);
  } else if (ids.length === 2) {
    ok(`${ids.length} URL elicitations, each with an elicitationId`);
  }
  if (new Set(ids).size !== ids.length) fail(`two URL elicitations have the same elicitationId: ${JSON.stringify(ids)}`);

  const completed = frames
    .filter((m) => m.method === "notifications/elicitation/complete" && !("id" in m))
    .map((m) => m.params?.elicitationId);
  let complete_ok = true;
  for (const id of ids) {
    const n = completed.filter((c) => c === id).length;
    if (n !== 1) {
      fail(`the elicitation ${id} got ${n} notifications/elicitation/complete, not 1`);
      complete_ok = false;
    }
  }
  for (const id of completed) {
    if (!ids.includes(id)) {
      fail(`notifications/elicitation/complete names an unknown elicitation: ${JSON.stringify(id)}`);
      complete_ok = false;
    }
  }
  if (complete_ok && ids.length > 0) ok("one notifications/elicitation/complete for each URL elicitation");

  const file_urls = frames.filter((m) => m.method === "elicitation/create" && String(m.params?.url ?? "").startsWith("file:"));
  if (file_urls.length === 0) {
    ok("no file URL came to the client");
  } else {
    fail(`the bridge sent a file URL to the client: ${JSON.stringify(file_urls[0].params.url)}`);
  }
}

async function checkInputRequests(client, frames) {
  const profile = await callText(client, "ask_form", {});
  if (profile !== undefined) {
    const prefix = "form: accept ";
    let content;
    try {
      if (profile.startsWith(prefix)) content = JSON.parse(profile.slice(prefix.length));
    } catch {
      content = undefined;
    }
    if (isDeepStrictEqual(content, profile_answer)) {
      ok(`tools/call ask_form -> ${JSON.stringify(profile)}`);
    } else {
      fail(`tools/call ask_form: expected the text ${JSON.stringify(prefix + JSON.stringify(profile_answer))}, got ${JSON.stringify(profile)}`);
    }
  }
  await callAndExpect(client, "ask_url", {}, "url: accept");
  // Round 2 asks for the same URL again. The bridge then sends the Continue form.
  await callAndExpect(client, "ask_url_twice", {}, "url twice: accept");
  // The bridge refuses a file URL and sends decline upstream.
  await callAndExpect(client, "ask_bad_url", {}, "url: decline");
  await callAndExpect(client, "sample", {}, "model: hello");
  await callAndExpect(client, "list_roots", {}, `roots: ${root_uri}`);
  // A form and roots/list in one round.
  await callAndExpect(client, "multi", {}, "name: Ada (accept); roots: 1");
  try {
    const prompt = await client.getPrompt({ name: "ask_name" });
    const text = prompt.messages?.[0]?.content?.text;
    if (text === "Hello, Ada.") {
      ok(`prompts/get ask_name -> ${JSON.stringify(text)}`);
    } else {
      fail(`prompts/get ask_name: expected the text "Hello, Ada.", got ${JSON.stringify(prompt.messages)}`);
    }
  } catch (err) {
    fail(`prompts/get ask_name: ${err?.message ?? err}`);
  }
  checkInputFrames(frames);
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
  // Each message from the bridge. Client.connect keeps this handler and calls it first.
  const frames = [];
  transport.onmessage = (message) => frames.push(message);
  const client = new Client({ name: "zig-bridge-sdk-interop", version: "0.0.0" }, { capabilities: input_capabilities });
  addInputHandlers(client);
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
  await checkInputRequests(client, frames);

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
