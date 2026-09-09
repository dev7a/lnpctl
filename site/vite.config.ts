import { existsSync } from 'node:fs';
import { sites } from '@openai/sites-vite-plugin';
import tailwindcss from '@tailwindcss/postcss';
import vinext from 'vinext';
import { defineConfig } from 'vite';

export default defineConfig({
  css: { postcss: { plugins: [tailwindcss()] } },
  // Ordinary local builds do not require an account-specific Sites binding.
  plugins: [vinext(), ...(existsSync('.openai/hosting.json') ? [sites()] : [])],
});
