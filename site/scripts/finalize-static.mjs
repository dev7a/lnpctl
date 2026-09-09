import { copyFileSync, mkdirSync } from 'node:fs';

// vinext beta.5 skips /guide during prerender when trailingSlash is enabled.
// Preserve its normal export and provide directory indexes for plain static hosts.
mkdirSync('dist/client/guide', { recursive: true });
copyFileSync('dist/client/guide.html', 'dist/client/guide/index.html');
