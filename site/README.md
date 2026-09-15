# lnpctl guide

A static tutorial for the experimental lnpctl Local Network permission cleanup tool. Source: https://github.com/dev7a/lnpctl.

Run lnpctl at your own risk and peril. It uses private CoreFoundation APIs and directly edits an undocumented macOS configuration format. The private functions are `_CFKeyedArchiverUIDGetValue` and `_CFKeyedArchiverUIDGetTypeID`; they inspect archive references, while lnpctl performs the file edits. Backups and checks do not guarantee safety.

## Develop

Use Node 22.13 or later. Install with `npm ci --ignore-scripts`, then run `npm run dev`. Build with `npm run build`. The static export is in `dist/client`; GitHub Pages publishes only that directory.

The screenshots and videos use controlled demonstration data and a disposable Tart VM. See the tool repository's validation record for the exact test coverage.

The published site is a static export; it does not deploy a Node server. Check the current lockfile with `npm audit --package-lock-only --ignore-scripts` when changing dependencies. Advisory applicability must be assessed against both the build environment and the files actually published. Do not expose the development server or use untrusted build inputs.

## Repository and deployment configuration

This directory is the website source within the lnpctl repository. It builds locally without a Sites account or credentials. It does not change the CLI build.

The actual `.openai/hosting.json` is local and ignored by Git. `.openai/hosting.example.json` contains only the static output directory. When binding a new Sites deployment, create the local configuration from that example and add the project ID returned by Sites. Do not reuse another account's project ID. Source credentials and deployment tokens must never be written into source files or Git remotes.

Only `dist/client` is the publishable build output. Do not publish the entire working directory. Environment files, dependencies, build output, deployment state, private keys, and local hosting configuration are ignored.

## Publication audit

The migration audit checked candidate source and lockfile text, ran Gitleaks with no findings, reviewed demonstration media, and checked media metadata. The included media shows synthetic picker data or disposable VM accounts named `demo` and `admin`; UUIDs and paths visible there belong to those test environments. No host recordings, VM images, SSH keys, raw permission stores, backups, account-specific deployment bindings, or prior site Git history are included.

This publication audit covers secrets and private information; it does not certify the dependency tree as vulnerability-free. Recheck new content and dependency changes before publishing them.

## Licenses

The project uses the [MIT license](../LICENSE). The copied shadcn/ui components and third-party client libraries retain their own notices in [THIRD_PARTY_NOTICES.txt](public/THIRD_PARTY_NOTICES.txt). Vite copies this public file into `dist/client`, so the notices accompany the deployed site even when minification removes comments.

The notice file records the installed package versions and includes the full applicable license texts, including Apache-2.0 for class-variance-authority and the Lucide/Feather notices. Refresh affected sections when updating client dependencies or copying more third-party source; preserve any additional upstream NOTICE files. Build-only dependencies are not redistributed as part of the static site.
