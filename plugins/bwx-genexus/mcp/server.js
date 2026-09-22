#!/usr/bin/env node
// Servidor MCP (stdio) que expone el bridge de GeneXus como herramientas.
// Sin dependencias: JSON-RPC 2.0 delimitado por lineas, que es el transporte stdio de MCP.
// Puerto y token se leen de %LOCALAPPDATA%\bwx-gx-bridge\session.json en cada llamada,
// asi que sobrevive a reinicios del IDE sin reiniciar el servidor.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const readline = require('readline');

// Claude Code puede lanzar el servidor sin LOCALAPPDATA en el entorno; sin este respaldo la ruta
// quedaba relativa al directorio de trabajo y la sesion "no existia" aunque el IDE estuviera abierto.
const LOCAL_APPDATA = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
const SESSION = path.join(LOCAL_APPDATA, 'bwx-gx-bridge', 'session.json');
const PROTOCOL = '2024-11-05';

const TOOLS = [
  {
    name: 'gx_status',
    description: 'Estado del bridge: KB abierta en el IDE de GeneXus y prefijos habilitados para escritura.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'gx_get_object',
    description:
      'Lee un objeto de la KB abierta en GeneXus: fuente de cada parte (Procedure, Rules, Conditions, Events...) ' +
      'con su hash, y sus variables. Los hashes se pasan a gx_set_source / gx_set_variables como control de concurrencia.',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Nombre del objeto' },
        type: { type: 'string', description: 'Tipo (Procedure, Transaction, WebPanel, SDT...). Obligatorio si el nombre es ambiguo.' },
        out_dir: {
          type: 'string',
          description:
            'Carpeta (ruta absoluta) donde guardar cada parte como <Nombre>.<Parte>.gx y las variables como ' +
            '<Nombre>.variables.json. Devuelve solo hashes y rutas. Usar con objetos grandes.',
        },
      },
      required: ['name'],
    },
  },
  {
    name: 'gx_set_source',
    description:
      'Reemplaza el fuente completo de una parte y guarda el objeto. GeneXus lo valida antes de guardar: ' +
      'si hay errores no guarda nada y los devuelve. Rechaza el cambio si el fuente cambio desde la lectura.',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string' },
        type: { type: 'string' },
        part: { type: 'string', description: 'Nombre de la parte tal como la devuelve gx_get_object (ej. Procedure, Rules)' },
        source: { type: 'string', description: 'Fuente completo de la parte' },
        source_file: { type: 'string', description: 'Alternativa a source: ruta absoluta a un archivo UTF-8 con el fuente completo' },
        expected_hash: { type: 'string', description: 'Hash de la parte devuelto por gx_get_object' },
      },
      required: ['name', 'part', 'expected_hash'],
    },
  },
  {
    name: 'gx_set_variables',
    description:
      'Agrega, modifica o elimina variables y guarda el objeto. El tipo de cada variable se da con uno de: ' +
      'basedOnAttribute, basedOnDomain, customType (formato copiado de otra variable, para SDT/BC/objetos externos) ' +
      'o dataType + length + decimals (NUMERIC, CHARACTER, VARCHAR, LONGVARCHAR, DATE, DATETIME, Boolean, GUID).',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string' },
        type: { type: 'string' },
        upsert: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              name: { type: 'string' },
              basedOnAttribute: { type: 'string' },
              basedOnDomain: { type: 'string' },
              customType: { type: 'string' },
              dataType: { type: 'string' },
              length: { type: 'integer' },
              decimals: { type: 'integer' },
              isCollection: { type: 'boolean' },
              description: { type: 'string' },
            },
            required: ['name'],
          },
        },
        remove: { type: 'array', items: { type: 'string' } },
        expected_hash: { type: 'string', description: 'variablesHash devuelto por gx_get_object' },
      },
      required: ['name', 'expected_hash'],
    },
  },
];

function session() {
  if (!fs.existsSync(SESSION)) {
    throw new Error('GeneXus no esta abierto o el bridge no arranco (ver %LOCALAPPDATA%\\bwx-gx-bridge\\bridge.log).');
  }
  return JSON.parse(fs.readFileSync(SESSION, 'utf8'));
}

function call(method, route, body) {
  const s = session();
  const payload = body === undefined ? null : Buffer.from(JSON.stringify(body), 'utf8');
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: '127.0.0.1',
        port: s.port,
        path: route,
        method,
        headers: Object.assign(
          { 'X-Bridge-Token': s.token },
          payload ? { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': payload.length } : {}
        ),
        timeout: 300000,
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          let json;
          try { json = JSON.parse(text); } catch { json = { error: text }; }
          resolve({ status: res.statusCode, body: json });
        });
      }
    );
    req.on('timeout', () => req.destroy(new Error('timeout del bridge')));
    req.on('error', (e) =>
      reject(e.code === 'ECONNREFUSED' ? new Error('el bridge no responde: GeneXus se cerro o se reinicio') : e));
    if (payload) req.write(payload);
    req.end();
  });
}

const q = (v) => encodeURIComponent(v);

async function runTool(name, a) {
  switch (name) {
    case 'gx_status':
      return call('GET', '/status');
    case 'gx_get_object':
      return call('GET', `/object?name=${q(a.name)}${a.type ? `&type=${q(a.type)}` : ''}`);
    case 'gx_set_source': {
      // Un procedure de miles de lineas no entra comodo como parametro: se puede pasar un archivo.
      if ((a.source === undefined) === (a.source_file === undefined)) throw new Error('indicar source o source_file (uno solo)');
      const source = a.source !== undefined ? a.source : fs.readFileSync(a.source_file, 'utf8').replace(/^\uFEFF/, '');
      return call('POST', '/source', { name: a.name, type: a.type, part: a.part, source, expectedHash: a.expected_hash });
    }
    case 'gx_set_variables':
      return call('POST', '/variables', {
        name: a.name, type: a.type, upsert: a.upsert || [], remove: a.remove || [], expectedHash: a.expected_hash,
      });
    default:
      throw new Error(`herramienta desconocida: ${name}`);
  }
}

// Presenta el objeto como texto legible: el fuente sin escapar es mucho mas facil de editar.
function render(name, res, args) {
  const b = res.body;
  if (name !== 'gx_get_object' || res.status !== 200) return JSON.stringify(b, null, 2);
  if (args && args.out_dir) return saveObject(b, args.out_dir);
  const out = [`${b.type} ${b.name}  (modificado ${b.lastUpdate})`, ''];
  for (const p of b.parts) {
    if (!p.isSource) continue;
    out.push(`===== parte: ${p.name}   hash: ${p.hash}`, p.source || '', '');
  }
  if (b.variables) {
    out.push(`===== variables   hash: ${b.variablesHash}`, JSON.stringify(b.variables, null, 1));
  }
  return out.join('\n');
}

// Guarda las partes en archivos y devuelve solo el indice: con objetos grandes el fuente
// inline se vuelve inmanejable para editar y para verificar con diff.
function saveObject(b, dir) {
  if (!path.isAbsolute(dir)) throw new Error('out_dir tiene que ser una ruta absoluta');
  fs.mkdirSync(dir, { recursive: true });
  const out = [`${b.type} ${b.name}  (modificado ${b.lastUpdate})`, ''];
  for (const p of b.parts) {
    if (!p.isSource) continue;
    const src = p.source || '';
    const file = path.join(dir, `${b.name}.${p.name}.gx`);
    fs.writeFileSync(file, src, 'utf8');
    out.push(`${p.name}   hash: ${p.hash}   ${src ? src.split('\n').length : 0} lineas   -> ${file}`);
  }
  if (b.variables) {
    const file = path.join(dir, `${b.name}.variables.json`);
    fs.writeFileSync(file, JSON.stringify(b.variables, null, 1), 'utf8');
    out.push(`variables   hash: ${b.variablesHash}   ${b.variables.length} variables   -> ${file}`);
  }
  return out.join('\n');
}

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

async function handle(msg) {
  const { id, method, params } = msg;
  if (id === undefined) return; // notificaciones (initialized, cancelled): no llevan respuesta
  try {
    let result;
    switch (method) {
      case 'initialize':
        result = {
          protocolVersion: (params && params.protocolVersion) || PROTOCOL,
          capabilities: { tools: {} },
          serverInfo: { name: 'bwx-gx-bridge', version: '0.3.0' },
        };
        break;
      case 'ping':
        result = {};
        break;
      case 'tools/list':
        result = { tools: TOOLS };
        break;
      case 'tools/call': {
        try {
          const res = await runTool(params.name, params.arguments || {});
          const failed = res.status !== 200 || res.body.saved === false;
          result = { content: [{ type: 'text', text: render(params.name, res, params.arguments) }], isError: failed };
        } catch (e) {
          result = { content: [{ type: 'text', text: e.message }], isError: true };
        }
        break;
      }
      default:
        send({ jsonrpc: '2.0', id, error: { code: -32601, message: `metodo no soportado: ${method}` } });
        return;
    }
    send({ jsonrpc: '2.0', id, result });
  } catch (e) {
    send({ jsonrpc: '2.0', id, error: { code: -32603, message: e.message } });
  }
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  handle(msg);
});
