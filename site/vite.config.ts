import { existsSync } from 'node:fs';
import { sites } from '@openai/sites-vite-plugin';
import tailwindcss from '@tailwindcss/postcss';
import vinext from 'vinext';
import { defineConfig } from 'vite';

export default defineConfig({
  // Vite prefixes built assets; raw page links use sitePath. Keep vinext routes
  // at root because beta.5 skips static prerenders when next.basePath is set.
  base: `${process.env.NEXT_PUBLIC_BASE_PATH ?? ''}/`,
  css: { postcss: { plugins: [tailwindcss()] } },
  // Ordinary local builds do not require an account-specific Sites binding.
  plugins: [vinext(), ...(existsSync('.openai/hosting.json') ? [sites()] : [])],
});
