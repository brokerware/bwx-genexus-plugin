#!/usr/bin/env node
// Registra el servidor MCP bwx-gx-bridge a nivel usuario en ~/.claude.json, que es lo que
// hace "claude mcp add -s user" pero sin necesitar el CLI (la app de escritorio no lo trae).
// Solo toca la entrada mcpServers["bwx-gx-bridge"]; el resto del archivo queda igual.
//   node register-mcp.js <ruta a server.js>
//   node register-mcp.js --remove
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const NAME = 'bwx-gx-bridge';
const file = path.join(os.homedir(), '.claude.json');
const arg = process.argv[2];
if (!arg) {
  console.error('uso: node register-mcp.js <server.js> | --remove');
  process.exit(2);
}

let config = {};
if (fs.existsSync(file)) {
  const text = fs.readFileSync(file, 'utf8');
  try {
    config = JSON.parse(text);
  } catch (e) {
    console.error(`${file} no es JSON valido; no lo toco. ${e.message}`);
    process.exit(1);
  }
  fs.writeFileSync(file + '.bwx-backup', text);
}

config.mcpServers = config.mcpServers || {};
let msg;
if (arg === '--remove') {
  delete config.mcpServers[NAME];
  msg = `MCP ${NAME} eliminado de ${file}`;
} else {
  const server = path.resolve(arg);
  if (!fs.existsSync(server)) {
    console.error(`no existe ${server}`);
    process.exit(1);
  }
  const prev = config.mcpServers[NAME];
  const same = prev && prev.command === 'node' && Array.isArray(prev.args) && prev.args[0] === server;
  config.mcpServers[NAME] = { type: 'stdio', command: 'node', args: [server], env: {} };
  msg = same ? `MCP ${NAME} ya registrado (${server})` : `MCP ${NAME} registrado -> ${server}`;
}

// Se escribe a un temporal y se renombra: Claude Code puede estar leyendo el archivo.
const tmp = file + '.bwx-tmp';
fs.writeFileSync(tmp, JSON.stringify(config, null, 2));
fs.renameSync(tmp, file);
console.log(msg);
