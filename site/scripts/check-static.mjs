import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve('dist/client');
const base = process.env.NEXT_PUBLIC_BASE_PATH ?? '';
for (const page of ['index.html', 'guide/index.html']) {
  const html = readFileSync(resolve(root, page), 'utf8');
  assert(html.includes('lnpctl'), `${page}: missing rendered content`);
  for (const [, url] of html.matchAll(/(?:href|src|poster)="([^"]+)"/g)) {
    if (!url.startsWith('/') || url.startsWith('//')) continue;
    assert(url.startsWith(`${base}/`), `${page}: URL outside deployment path: ${url}`);
    const local = url.slice(base.length).split(/[?#]/)[0];
    const target = resolve(root, `.${local}`, local.endsWith('/') ? 'index.html' : '');
    assert(existsSync(target), `${page}: missing local target: ${url}`);
  }
}
for (const media of ['media/lnpctl-demo.mp4', 'media/full-walkthrough/lnpctl-quick-walkthrough.mp4']) {
  assert(existsSync(resolve(root, media)), `Missing video: ${media}`);
}
console.log(`Static pages and local links verified for ${base || '/'}`);
