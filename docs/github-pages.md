# GitHub Pages

The site exports HTML, JavaScript, CSS, images, subtitles, and video. It needs no running server. The project site is built for `https://dev7a.github.io/lnpctl/`; ordinary builds still use `/` for the existing Sites host.

Enable Pages with **GitHub Actions** as its source in repository Settings → Pages. Protect the `github-pages` environment so only `main` can deploy. Enabling Pages publishes the website even while the repository is private; keep the repository private until its separate publication review is complete.

## Build locally

```sh
cd site
npm ci --ignore-scripts --no-audit --no-fund
NEXT_PUBLIC_BASE_PATH=/lnpctl npm run build
NEXT_PUBLIC_BASE_PATH=/lnpctl node scripts/check-static.mjs
```

Omit `NEXT_PUBLIC_BASE_PATH` for a root-hosted build. No credentials or Sites binding are needed. The output is `site/dist/client`. Serve that directory mounted at `/lnpctl/` to preview the Pages build. Links include the prefix and the guide has a directory index for `/lnpctl/guide/`.

## Workflow and security

`.github/workflows/pages.yml` has no default token permissions. Pull requests affecting the site or workflow build their merge ref with only `contents: read`, no checkout credentials persisted, no secrets, and no deployment. A push to `main` builds the event commit. A manual dispatch builds the selected ref, but only an exact `refs/heads/main` dispatch may upload and deploy. Node dependencies come from the committed lockfile with lifecycle scripts disabled; automatic setup-node caching is disabled.

The build uploads a uniquely named artifact containing only `site/dist/client`. The deploy job never checks out or executes repository code. It consumes that same build's artifact name through a job output and uses the GitHub Actions token with only `pages: write` and `id-token: write`, behind the `github-pages` environment. It creates no commits, tags, releases, or downstream workflow triggers. GitHub validates the deployment's OIDC identity.

The workflow serializes runs per ref without cancelling an in-progress publication. A failed build cannot deploy. A failed deployment leaves the previous site live; retry the failed deployment while its artifact is retained (one day). Re-running all jobs creates an artifact for the new run attempt. Re-running only a failed deployment uses the artifact name from its successful build. A manual rerun of an older successful run can intentionally restore older content, so use a new dispatch on `main` for the latest site. No artifact or ref cleanup is required.

Action entry points are pinned to verified GitHub action release commits. The Pages upload action itself pins its nested `actions/upload-artifact` dependency. Node 24 and the Ubuntu 24.04 hosted runner remain moving, maintained runtime selections; npm dependencies remain locked.

References: [GitHub custom Pages workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages), [Pages deployment action](https://github.com/actions/deploy-pages), [Pages artifact action](https://github.com/actions/upload-pages-artifact).
