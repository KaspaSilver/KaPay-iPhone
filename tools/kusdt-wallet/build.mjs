// Builds KaPay's pinned copy of Trestly's kUSDT wallet logic:
//   KUSDT_OPEN=/path/to/kusdt-open node build.mjs
// kusdt-open must be checked out at the commit KaPay pins (Kusdt.swift / KusdtCore.swift say which).
// Writes ../../KaChatWallet/Resources/KusdtCore/kusdt-wallet.js.txt and prints its SHA-256 for
// KusdtCore.pinned. The aliases are the extension's own (wallet/extension/aliases.ts), except that
// the core's web loader is stubbed: KaPay's page has loaded the WebAssembly already.
import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const open = path.resolve(process.env.KUSDT_OPEN ?? path.join(here, '../../../kusdt-open'));
const ext = path.join(open, 'wallet/extension/src');
const pkgs = path.join(open, 'bridge/packages');
const out = path.resolve(here, '../../KaChatWallet/Resources/KusdtCore/kusdt-wallet.js.txt');

const commit = execSync('git rev-parse --short HEAD', { cwd: open }).toString().trim();

const aliases = [
  [/^@\/(.*)$/, (m) => path.join(ext, m[1])],
  [/^@kusdt\/kaspa$/, () => path.join(pkgs, 'kaspa/src/index.ts')],
  [/^@kusdt\/kaspa\/(.*)$/, (m) => path.join(pkgs, 'kaspa/src', m[1] + '.ts')],
  [/^@kusdt\/protocol$/, () => path.join(pkgs, 'protocol/src/index.ts')],
  [/^@kusdt\/core\/web$/, () => path.join(here, 'src/web-stub.ts')],
  [/^@kusdt\/core\/core$/, () => path.join(pkgs, 'core/src/core.ts')],
  [/^@kusdt\/core-wasm(\?url)?$/, () => path.join(here, 'src/wasm-url-stub.ts')],
];

const resolveAliases = {
  name: 'kusdt-aliases',
  setup(b) {
    b.onResolve({ filter: /^(@\/|@kusdt\/)/ }, async (args) => {
      for (const [re, to] of aliases) {
        const m = args.path.match(re);
        if (!m) continue;
        let target = to(m);
        // `@/x/y` may name a .ts or .tsx file, or a folder's index
        const r = await b.resolve(target.startsWith('.') ? target : './' + path.relative(args.resolveDir || here, target), { resolveDir: args.resolveDir || here, kind: args.kind });
        if (r.errors.length) return { errors: r.errors };
        return { path: r.path };
      }
      return undefined;
    });
    // The page's own copy of the WebAssembly loader, already initialised: never bundled.
    b.onResolve({ filter: /^\.\/kusdt_wasm\.js$/ }, () => ({ path: './kusdt_wasm.js', external: true }));
  },
};

const result = await build({
  entryPoints: [path.join(here, 'src/entry.ts')],
  bundle: true,
  format: 'esm',
  platform: 'browser',
  target: ['safari16'],
  write: false,
  minify: false,
  legalComments: 'inline',
  nodePaths: [path.join(here, 'node_modules')],
  plugins: [resolveAliases],
  banner: { js: `// Trestly's kUSDT wallet logic, kaspador/kusdt-open ${commit} (wallet/extension/src/kusdt), built for KaPay by tools/kusdt-wallet.` },
  logLevel: 'warning',
});

const code = result.outputFiles[0].contents;
writeFileSync(out, code);
const sha = createHash('sha256').update(readFileSync(out)).digest('hex');
console.log(`kusdt-open ${commit}`);
console.log(`${path.relative(process.cwd(), out)} ${code.length} bytes`);
console.log(`sha256 ${sha}`);
