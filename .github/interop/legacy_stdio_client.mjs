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
// - gets the notifications of the bridge through the notification handlers of the SDK, as VS
//   Code does, and asserts that the initialize result declares tools, prompts and resources
//   listChanged, resources.subscribe and logging;
// - asserts that the client gets one list change of each list after the start;
// - calls the tool toggle, and asserts that the list change comes before the result of the
//   call, and that the next tools/list or prompts/list shows the change;
// - subscribes to a resource, and asserts that notifications/resources/updated comes before
//   the result of the tool touch, without _meta, and that no update comes after
//   resources/unsubscribe;
// - sets the log level with logging/setLevel, and asserts that the log messages of the tool log
//   at that level and above come before the result of the call;
// - asserts that no notifications/cancelled comes to the client;
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
  ToolListChangedNotificationSchema,
  PromptListChangedNotificationSchema,
  ResourceListChangedNotificationSchema,
  ResourceUpdatedNotificationSchema,
  LoggingMessageNotificationSchema,
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
// The time that the client waits for the list changes after the start.
const start_wait_ms = 10_000;
// The text resource of bridge-fixture-server (notes_uri and notes_text of test/fixture.zig).
const notes_uri = "file:///fixture/notes.txt";
const notes_text = "The notes of the fixture.";
// The levels and the logger of the log messages of the tool log (log_levels and log_logger of
// test/fixture.zig).
const log_levels = ["debug", "info", "warning", "error"];
const log_logger = "fixture";

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

// The list changes of the bridge, by the list that VS Code lists again.
const list_changes = {
  tools: "notifications/tools/list_changed",
  prompts: "notifications/prompts/list_changed",
  resources: "notifications/resources/list_changed",
};

// What the notification handlers of the SDK got, in the order of arrival. The SDK checks each
// notification against its schema of revision 2025-11-25 before it calls the handler. A
// notification that is not valid goes to client.onerror.
const handled = { tools: 0, prompts: 0, resources: 0, updates: [], logs: [] };

// VS Code lists the tools, the prompts or the resources again after a list change, reads a
// subscribed resource again after an update, and shows the log messages. The handlers record
// the notifications only.
function addNotificationHandlers(client) {
  client.setNotificationHandler(ToolListChangedNotificationSchema, () => {
    handled.tools += 1;
  });
  client.setNotificationHandler(PromptListChangedNotificationSchema, () => {
    handled.prompts += 1;
  });
  client.setNotificationHandler(ResourceListChangedNotificationSchema, () => {
    handled.resources += 1;
  });
  client.setNotificationHandler(ResourceUpdatedNotificationSchema, (notification) => {
    handled.updates.push(notification.params);
  });
  client.setNotificationHandler(LoggingMessageNotificationSchema, (notification) => {
    handled.logs.push(notification.params);
  });
}

function isResponse(message) {
  return "id" in message && !("method" in message);
}

// Wait until predicate() is true. Returns false after timeout_ms.
async function waitFor(predicate, timeout_ms) {
  const end = Date.now() + timeout_ms;
  while (!predicate()) {
    if (Date.now() >= end) return false;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return true;
}

// Call the tool `name`, and assert the text of its result. Returns the messages from the
// bridge that came after the request and before the response, or undefined after a failure.
// The calls of this check are sequential, thus the first response after the request is the
// response of the call.
async function callWithNotifications(client, frames, name, args, expected) {
  const from = frames.length;
  const text = await callText(client, name, args);
  if (text === undefined) return undefined;
  if (text !== expected) {
    fail(`tools/call ${name}: expected the text ${JSON.stringify(expected)}, got ${JSON.stringify(text)}`);
    return undefined;
  }
  const after = frames.slice(from);
  const response = after.findIndex(isResponse);
  if (response === -1) {
    fail(`tools/call ${name}: the response is not in the messages of the bridge`);
    return undefined;
  }
  return after.slice(0, response);
}

// The names of all tools or prompts, page by page as VS Code lists them, or undefined after a
// failure. `kind` is "tools" or "prompts".
async function listNames(client, kind) {
  const names = new Set();
  let cursor;
  let pages = 0;
  try {
    do {
      const params = cursor === undefined ? {} : { cursor };
      const page = kind === "tools" ? await client.listTools(params) : await client.listPrompts(params);
      pages += 1;
      for (const item of page[kind]) names.add(item.name);
      cursor = typeof page.nextCursor === "string" ? page.nextCursor : undefined;
    } while (cursor !== undefined && pages < max_pages);
  } catch (err) {
    fail(`${kind}/list: ${err?.message ?? err}`);
    return undefined;
  }
  return names;
}

// The initialize result declares the notifications that bridge-fixture-server declares.
function checkNotificationCapabilities(capabilities) {
  const declared = [
    ["tools.listChanged", capabilities?.tools?.listChanged === true],
    ["prompts.listChanged", capabilities?.prompts?.listChanged === true],
    ["resources.listChanged", capabilities?.resources?.listChanged === true],
    ["resources.subscribe", capabilities?.resources?.subscribe === true],
    ["logging", typeof capabilities?.logging === "object" && capabilities.logging !== null],
  ];
  const missing = declared.filter(([, present]) => !present).map(([name]) => name);
  if (missing.length === 0) {
    ok(`capabilities: ${declared.map(([name]) => name).join(", ")}`);
  } else {
    fail(`capabilities: ${missing.join(", ")} missing: ${JSON.stringify(capabilities)}`);
  }
}

// After the acknowledgment of its first listen stream, the bridge sends one list change for
// each list, because the lists of the client can be old.
async function checkStartListChanges(frames) {
  const methods = Object.values(list_changes);
  await waitFor(() => methods.every((method) => frames.some((m) => m.method === method)), start_wait_ms);
  let start_ok = true;
  for (const method of methods) {
    const count = frames.filter((m) => m.method === method).length;
    if (count !== 1) {
      fail(`expected one ${method} after the start, got ${count}`);
      start_ok = false;
    }
  }
  for (const kind of Object.keys(list_changes)) {
    if (handled[kind] !== 1) {
      fail(`the handler of ${list_changes[kind]} got ${handled[kind]} notifications after the start, not 1`);
      start_ok = false;
    }
  }
  if (start_ok) ok("one list change of the tools, the prompts and the resources after the start");
}

// The tool toggle enables or disables the tool toggled or the prompt toggled. The upstream
// server writes the list change before the result, and the bridge keeps that order. Thus the
// handler of the SDK runs before the call returns, and VS Code can list again before its next
// step.
async function checkToggle(client, frames, target, enabled) {
  const kind = target === "tool" ? "tools" : "prompts";
  const method = list_changes[kind];
  const state = enabled ? "enabled" : "disabled";
  const before = handled[kind];
  const notifications = await callWithNotifications(client, frames, "toggle", { enabled, target }, `${target} toggled: ${state}`);
  if (notifications === undefined) return;
  const changes = notifications.filter((m) => m.method === method).length;
  if (changes !== 1) {
    fail(`toggle ${target} ${state}: expected one ${method} before the result, got ${changes}`);
  } else if (handled[kind] !== before + 1) {
    fail(`toggle ${target} ${state}: the handler of ${method} got ${handled[kind] - before} notifications before the call returned, not 1`);
  } else {
    ok(`toggle ${target} ${state}: ${method} came before the result`);
  }
  const names = await listNames(client, kind);
  if (names === undefined) return;
  if (names.has("toggled") === enabled) {
    ok(`${kind}/list after the change ${enabled ? "has" : "does not have"} toggled`);
  } else {
    fail(`${kind}/list after the change ${enabled ? "does not have" : "has"} toggled`);
  }
}

// resources/subscribe and resources/unsubscribe. The upstream server writes the update before
// the result of the tool touch.
async function checkSubscription(client, frames) {
  try {
    await client.subscribeResource({ uri: notes_uri });
    ok(`resources/subscribe ${notes_uri}`);
  } catch (err) {
    fail(`resources/subscribe ${notes_uri}: ${err?.message ?? err}`);
    return;
  }
  const before = handled.updates.length;
  const notifications = await callWithNotifications(client, frames, "touch", { uri: notes_uri }, `touched ${notes_uri}`);
  if (notifications !== undefined) {
    const updates = notifications.filter((m) => m.method === "notifications/resources/updated");
    if (updates.length !== 1 || updates[0].params?.uri !== notes_uri) {
      fail(`touch: expected one notifications/resources/updated for ${notes_uri} before the result, got ${JSON.stringify(updates)}`);
    } else if ("_meta" in updates[0].params) {
      // The subscription id of the upstream server does not come to the client.
      fail(`touch: the update has _meta: ${JSON.stringify(updates[0].params)}`);
    } else if (handled.updates.length !== before + 1) {
      fail(`touch: the handler of notifications/resources/updated got ${handled.updates.length - before} notifications before the call returned, not 1`);
    } else {
      ok("touch: notifications/resources/updated came before the result, without _meta");
    }
  }
  try {
    const read = await client.readResource({ uri: notes_uri });
    const text = read.contents?.[0]?.text;
    if (text === notes_text) {
      ok(`resources/read ${notes_uri} -> ${JSON.stringify(text)}`);
    } else {
      fail(`resources/read ${notes_uri}: expected the text ${JSON.stringify(notes_text)}, got ${JSON.stringify(read.contents)}`);
    }
  } catch (err) {
    fail(`resources/read ${notes_uri}: ${err?.message ?? err}`);
  }
  try {
    await client.unsubscribeResource({ uri: notes_uri });
    ok(`resources/unsubscribe ${notes_uri}`);
  } catch (err) {
    fail(`resources/unsubscribe ${notes_uri}: ${err?.message ?? err}`);
    return;
  }
  const after = handled.updates.length;
  const late = await callWithNotifications(client, frames, "touch", { uri: notes_uri }, `touched ${notes_uri}`);
  if (late === undefined) return;
  if (late.some((m) => m.method === "notifications/resources/updated") || handled.updates.length !== after) {
    fail("touch: an update came after resources/unsubscribe");
  } else {
    ok("touch: no update after resources/unsubscribe");
  }
}

// logging/setLevel. On stdio, the log messages of the upstream server go to the bridge on the
// reader task of its upstream client, before the result of the call.
async function checkLogging(client, frames) {
  const cases = [
    ["debug", log_levels],
    ["warning", ["warning", "error"]],
  ];
  for (const [level, expected] of cases) {
    try {
      await client.setLoggingLevel(level);
    } catch (err) {
      fail(`logging/setLevel ${level}: ${err?.message ?? err}`);
      continue;
    }
    const before = handled.logs.length;
    const notifications = await callWithNotifications(client, frames, "log", {}, `logged ${log_levels.length} messages`);
    if (notifications === undefined) continue;
    const messages = notifications.filter((m) => m.method === "notifications/message").map((m) => m.params ?? {});
    const levels = messages.map((p) => p.level);
    const bad = messages.find((p) => p.logger !== log_logger || typeof p.data !== "string" || "_meta" in p);
    if (!isDeepStrictEqual(levels, expected)) {
      fail(`logging/setLevel ${level}: expected the log levels ${JSON.stringify(expected)} before the result of log, got ${JSON.stringify(levels)}`);
    } else if (bad !== undefined) {
      fail(`logging/setLevel ${level}: a log message is not as expected: ${JSON.stringify(bad)}`);
    } else if (handled.logs.length !== before + expected.length) {
      fail(`logging/setLevel ${level}: the handler of notifications/message got ${handled.logs.length - before} messages before the call returned, not ${expected.length}`);
    } else {
      ok(`logging/setLevel ${level}: the levels ${levels.join(", ")} came before the result of log`);
    }
  }
}

async function checkNotifications(client, frames) {
  checkNotificationCapabilities(client.getServerCapabilities());
  await checkStartListChanges(frames);
  await checkToggle(client, frames, "tool", false);
  await checkToggle(client, frames, "tool", true);
  await checkToggle(client, frames, "prompt", false);
  await checkToggle(client, frames, "prompt", true);
  await checkSubscription(client, frames);
  // The log level stays for the next requests, thus this check is the last one.
  await checkLogging(client, frames);
  // The ids of the upstream requests of the bridge can be equal to the ids of the client. Thus
  // a cancellation of the upstream server never comes to the client. In this check, the bridge
  // also cancels none of its own requests.
  const cancelled = frames.filter((m) => m.method === "notifications/cancelled");
  if (cancelled.length === 0) {
    ok("no notifications/cancelled came to the client");
  } else {
    fail(`the client got notifications/cancelled: ${JSON.stringify(cancelled)}`);
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
  // Each message from the bridge. Client.connect keeps this handler and calls it first.
  const frames = [];
  transport.onmessage = (message) => frames.push(message);
  const client = new Client({ name: "zig-bridge-sdk-interop", version: "0.0.0" }, { capabilities: input_capabilities });
  addInputHandlers(client);
  // Before connect: the list changes after the start can come at once after initialize.
  addNotificationHandlers(client);
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
  await checkNotifications(client, frames);

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
