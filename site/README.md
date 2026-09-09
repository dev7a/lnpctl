# lnpctl guide

A static tutorial for the experimental lnpctl Local Network permission cleanup tool. Source: https://github.com/dev7a/lnpctl (private).

Run lnpctl at your own risk and peril. It uses private CoreFoundation APIs and directly edits an undocumented macOS configuration format. The private functions are `_CFKeyedArchiverUIDGetValue` and `_CFKeyedArchiverUIDGetTypeID`; they inspect archive references, while lnpctl performs the file edits. Backups and checks do not guarantee safety.

## Develop

Use Node 22.13 or later. Install with `npm ci --ignore-scripts`, then run `npm run dev`. Build with `npm run build`. The static export is in `dist/client`; Sites publishes only that directory.

The screenshots and videos use controlled demonstration data and a disposable Tart VM. See the tool repository's validation record for the exact test coverage.

The starter's React packages are patched to 19.2.8. Remaining npm audit findings affect the retained build and development toolchain; no Node server, RSC request handler, image processor, or Cloudflare development runtime is published. Do not expose the development server or use untrusted build inputs.

## Repository and deployment configuration

This directory is the website source within the lnpctl repository. It builds locally without a Sites account or credentials. It does not change the CLI build.

The actual `.openai/hosting.json` is local and ignored by Git. `.openai/hosting.example.json` contains only the static output directory. When binding a new Sites deployment, create the local configuration from that example and add the project ID returned by Sites. Do not reuse another account's project ID. Source credentials and deployment tokens must never be written into source files or Git remotes.

Only `dist/client` is the publishable build output. Do not publish the entire working directory. Environment files, dependencies, build output, deployment state, private keys, and local hosting configuration are ignored.

## Publication audit

The migration audit checked candidate source and lockfile text, ran Gitleaks with no findings, reviewed demonstration media, and checked media metadata. The included media shows synthetic picker data or disposable VM accounts named `demo` and `admin`; UUIDs and paths visible there belong to those test environments. No host recordings, VM images, SSH keys, raw permission stores, backups, account-specific deployment bindings, or prior site Git history are included.

The dependency versions and lockfile are unchanged from the existing site. This audit covers secrets and private information; it does not certify the development dependency tree as vulnerability-free. Recheck new content before publishing it.
