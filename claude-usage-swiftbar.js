#!/usr/bin/env node

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const claudeProjectsDir =
  process.env.CLAUDE_PROJECTS_DIR || path.join(os.homedir(), ".claude", "projects");

const now = new Date();
const todayStart = new Date(now);
todayStart.setHours(0, 0, 0, 0);
const fiveHoursAgo = new Date(now.getTime() - 5 * 60 * 60 * 1000);

const totals = {
  today: emptyUsage(),
  window5h: emptyUsage(),
  allTime: emptyUsage(),
};
const byModel = new Map();
const seenRequests = new Set();

main();

function main() {
  if (!fs.existsSync(claudeProjectsDir)) {
    renderError(`No Claude logs found at ${claudeProjectsDir}`);
    return;
  }

  for (const file of walkJsonl(claudeProjectsDir)) {
    readUsageFromFile(file);
  }

  renderSwiftBar();
}

function readUsageFromFile(file) {
  let content;

  try {
    content = fs.readFileSync(file, "utf8");
  } catch {
    return;
  }

  for (const line of content.split("\n")) {
    if (!line.trim()) continue;

    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }

    const usage = event?.message?.usage;
    const timestamp = event?.timestamp ? new Date(event.timestamp) : null;

    if (!usage || !timestamp || Number.isNaN(timestamp.getTime())) continue;

    const requestKey =
      event.requestId ||
      `${event.message?.id || "unknown"}:${event.timestamp}:${file}`;

    if (seenRequests.has(requestKey)) continue;
    seenRequests.add(requestKey);

    const normalized = normalizeUsage(usage);
    addUsage(totals.allTime, normalized);

    if (timestamp >= todayStart) addUsage(totals.today, normalized);
    if (timestamp >= fiveHoursAgo) addUsage(totals.window5h, normalized);

    const model = event.message?.model || "unknown";
    if (!byModel.has(model)) byModel.set(model, emptyUsage());
    addUsage(byModel.get(model), normalized);
  }
}

function renderSwiftBar() {
  const title = totals.today.total
    ? `Claude ${formatCompact(totals.today.total)}`
    : "Claude 0";

  console.log(`${title} | refresh=true`);
  console.log("---");
  console.log(`Today: ${formatNumber(totals.today.total)} tokens`);
  console.log(`Last 5h: ${formatNumber(totals.window5h.total)} tokens`);
  console.log(`All time: ${formatNumber(totals.allTime.total)} tokens`);
  console.log("---");
  console.log(`Input today: ${formatNumber(totals.today.input)}`);
  console.log(`Output today: ${formatNumber(totals.today.output)}`);
  console.log(`Cache created today: ${formatNumber(totals.today.cacheCreate)}`);
  console.log(`Cache read today: ${formatNumber(totals.today.cacheRead)}`);
  console.log("---");

  const models = [...byModel.entries()]
    .sort((a, b) => b[1].total - a[1].total)
    .slice(0, 8);

  if (models.length) {
    console.log("Top models");
    for (const [model, usage] of models) {
      console.log(`--${model}: ${formatCompact(usage.total)}`);
    }
    console.log("---");
  }

  console.log("Refresh | refresh=true");
  console.log(
    `Open Claude logs | bash=open param1=${shellQuote(claudeProjectsDir)} terminal=false`
  );
}

function renderError(message) {
  console.log("Claude ?");
  console.log("---");
  console.log(message);
}

function* walkJsonl(dir) {
  let entries;

  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      yield* walkJsonl(fullPath);
    } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
      yield fullPath;
    }
  }
}

function normalizeUsage(usage) {
  const input = numeric(usage.input_tokens);
  const output = numeric(usage.output_tokens);
  const nestedCacheCreate =
    numeric(usage.cache_creation?.ephemeral_5m_input_tokens) +
    numeric(usage.cache_creation?.ephemeral_1h_input_tokens);
  const cacheCreate =
    usage.cache_creation_input_tokens === undefined
      ? nestedCacheCreate
      : numeric(usage.cache_creation_input_tokens);
  const cacheRead = numeric(usage.cache_read_input_tokens);

  return {
    input,
    output,
    cacheCreate,
    cacheRead,
    total: input + output + cacheCreate + cacheRead,
  };
}

function emptyUsage() {
  return {
    input: 0,
    output: 0,
    cacheCreate: 0,
    cacheRead: 0,
    total: 0,
  };
}

function addUsage(target, usage) {
  target.input += usage.input;
  target.output += usage.output;
  target.cacheCreate += usage.cacheCreate;
  target.cacheRead += usage.cacheRead;
  target.total += usage.total;
}

function numeric(value) {
  return Number.isFinite(value) ? value : 0;
}

function formatNumber(value) {
  return Math.round(value).toLocaleString();
}

function formatCompact(value) {
  return new Intl.NumberFormat("en", {
    notation: "compact",
    maximumFractionDigits: value >= 1_000_000 ? 1 : 0,
  }).format(Math.round(value));
}

function shellQuote(value) {
  if (!value) return "''";
  return `'${value.replace(/'/g, "'\\''")}'`;
}
