// Fetch only the Android entries from the official ZIP using HTTP byte ranges.
// Node 18+. No npm dependencies. Editor and templates must use the same version.
import { mkdir, writeFile } from 'node:fs/promises';
import { inflateRawSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const url = 'https://github.com/godotengine/godot/releases/download/4.5.1-stable/Godot_v4.5.1-stable_export_templates.tpz';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.join(root, '.tools/godot/editor_data/export_templates/4.5.1.stable');
const head = await fetch(url, { method: 'HEAD', signal: AbortSignal.timeout(60000) });
if (!head.ok) throw new Error(`Template HEAD failed: ${head.status}`);
const size = Number(head.headers.get('content-length'));
if (!Number.isSafeInteger(size) || size < 65536) throw new Error('Invalid template size');
const resolved = head.url;
async function range(start, end) {
  const response = await fetch(resolved, { headers: { Range: `bytes=${start}-${end}` }, signal: AbortSignal.timeout(180000) });
  if (response.status !== 206) throw new Error(`Server does not support byte ranges: ${response.status}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length !== end - start + 1) throw new Error('Incomplete range download');
  return bytes;
}
const tail = await range(size - 65536, size - 1);
const eocd = tail.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
if (eocd < 0) throw new Error('ZIP end record not found');
const directorySize = tail.readUInt32LE(eocd + 12);
const directoryOffset = tail.readUInt32LE(eocd + 16);
const directory = await range(directoryOffset, directoryOffset + directorySize - 1);
const wanted = new Set(['templates/android_debug.apk', 'templates/android_release.apk']);
await mkdir(output, { recursive: true });
for (let cursor = 0; cursor < directory.length;) {
  if (directory.readUInt32LE(cursor) !== 0x02014b50) throw new Error('Invalid ZIP directory');
  const method = directory.readUInt16LE(cursor + 10);
  const compressed = directory.readUInt32LE(cursor + 20);
  const uncompressed = directory.readUInt32LE(cursor + 24);
  const nameLength = directory.readUInt16LE(cursor + 28);
  const extraLength = directory.readUInt16LE(cursor + 30);
  const commentLength = directory.readUInt16LE(cursor + 32);
  const offset = directory.readUInt32LE(cursor + 42);
  const name = directory.subarray(cursor + 46, cursor + 46 + nameLength).toString('utf8');
  if (wanted.has(name)) {
    console.log(`Downloading ${name} (${Math.round(compressed / 1048576)} MB)`);
    const local = await range(offset, offset + 29);
    if (local.readUInt32LE(0) !== 0x04034b50) throw new Error('Invalid local ZIP header');
    const start = offset + 30 + local.readUInt16LE(26) + local.readUInt16LE(28);
    const data = await range(start, start + compressed - 1);
    const extracted = method === 8 ? inflateRawSync(data) : method === 0 ? data : null;
    if (!extracted || extracted.length !== uncompressed) throw new Error('Invalid extracted template');
    await writeFile(path.join(output, path.basename(name)), extracted);
    wanted.delete(name);
    console.log(`Installed ${path.basename(name)}`);
  }
  cursor += 46 + nameLength + extraLength + commentLength;
}
if (wanted.size) throw new Error('Missing Android templates');
await writeFile(path.join(root, '.tools/godot/_sc_'), '');
console.log('Android export templates ready.');
