# Signed releases

The Release workflow builds an Apple Silicon executable for macOS 15 or later, signs it with Developer ID, and submits a DMG to Apple. Publication requires an `Accepted` notarization result, a stapled ticket, signature verification, and Gatekeeper assessment. A bare command-line executable cannot carry a stapled ticket, so downloads use a DMG containing `lnpctl` and installation instructions.

## Configure GitHub

Use GitHub-hosted runners. Create a `release` environment and allow deployments from the `main` branch and version tags matching `v*`. The main rule permits manual dispatch; the tag rule permits tag-push releases. Protect those tags against modification and restrict who can create them. An optional required reviewer can control access to signing credentials. Release scripts execute the tagged source, so tag creation is a privileged maintainer action.

### Repository protections

The repository uses three active rulesets:

- `main` requires a pull request, verified commit signatures, resolved review threads, and the GitHub Actions checks `CLI tests (macos-15)` and `CLI tests (macos-26)` against the current base. Deletion and force pushes are blocked, with no bypass actors.
- Version tags matching `v*` can be created only by the designated release owner, `alessandrobologna`.
- A separate rule blocks updates and deletion of existing version tags for everyone, including the release owner. Release a new version to correct an existing release.

The sole maintainer cannot approve their own PR, so GitHub's required human approval count is zero. Exact-head Codex review remains a maintainer merge requirement; a clean review is not permission to skip failing CI. When adding maintainers, configure an independent required reviewer as well. Repository administrators can edit rulesets, so these protections do not defend against a compromised administrator account.

Before public releases, configure the `release` environment with `alessandrobologna` as a required reviewer and disable administrator bypass. With one maintainer, leave self-review prevention off so the owner can explicitly approve their own release; enable it when an independent release reviewer is available. Inspect the tag, commit, and workflow before approving access to signing credentials. GitHub Team supports required environment reviewers only for public repositories, so this approval gate must be enabled when the repository becomes public. Until then, the restricted tag creator and protected `main` are the enforced controls. See [GitHub environment protection availability](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).

Set these environment secrets through GitHub Settings or `gh secret set` reading from files or standard input. Never paste private keys into logs, source files, or issue comments.

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64 of an exported Developer ID Application certificate **and private key** |
| `DEVELOPER_ID_P12_PASSWORD` | Nonempty password protecting that export |
| `APPLE_API_KEY_BASE64` | Base64 of an App Store Connect team API `.p8` key authorized for notarization |

Set these environment variables:

| Variable | Value |
| --- | --- |
| `DEVELOPER_ID_IDENTITY` | SHA-1 fingerprint of the imported Developer ID Application identity |
| `APPLE_TEAM_ID` | The certificate's Apple developer team ID |
| `APPLE_API_KEY_ID` | Notarization API key ID |
| `APPLE_API_ISSUER_ID` | Notarization API issuer ID |

Exporting a local private key and uploading it to GitHub requires the key owner's explicit authorization. The workflow does not provision credentials. It imports the provided P12 into a temporary runner keychain, masks the random keychain password, and deletes both the keychain and key files in an `always()` cleanup step. GitHub destroys the hosted VM after the job even if cleanup fails. Do not change this job to a persistent self-hosted runner without revisiting credential cleanup and isolation.

## Publish a version

1. Update `src/LNPVersion.h`, which is the single source for CLI and backup-manifest versions. Merge the reviewed change to `main` after CI passes.
2. Create and push a signed version tag, for example `git tag -s v0.1.4 -m 'lnpctl 0.1.4'` and `git push origin v0.1.4`. Choose a tag that matches the source version exactly.
3. Watch Release. The final release contains the notarized DMG, `SHA256SUMS`, and `release.json` with the exact source commit, Xcode version, and Apple's result.

The tag must already exist, be an annotated OpenPGP-signed tag, and point to a commit on `main`. Preflight verifies its signature using only `tools/release/trusted-signers.asc` fetched from `main` in an isolated keyring. The approved key fingerprint is `BECE0982C01016F1367539EED9FA71FDAFA13545`. Add or rotate approved public keys through a reviewed main-branch change before using them for releases; no private keys belong in this file. Lightweight, unsigned, and unapproved-signer tags are rejected. Manual dispatch is available only from `main` with an existing tag; it creates no tag. A repository that remains private also keeps its release downloads private. Making the repository public is a separate action.

To verify a download, run `shasum -a 256 -c SHA256SUMS` in its directory, then `xcrun stapler validate lnpctl-0.1.4-macos-arm64.dmg`. Mount the DMG and copy `lnpctl` to a directory you own. There is no installer or automatic privileged execution.

## Event flow, privileges, and failure handling

All workflows start with `permissions: {}`. CI runs on main pushes, pull-request merge refs, and manual dispatches; it has only `contents: read`, no secrets, and no persisted checkout credentials. It builds/tests on macOS 15 and 26 ARM64 hosted images.

Release starts on a human-pushed `v*` tag or a main-only manual dispatch. The unprivileged preflight verifies the tag with the main-branch approved public key, resolves it to a commit, verifies ancestry against the fetched `origin/main`, and checks the header version, and binds pushed tags to their original event commit. The signing job checks out that immutable commit with `contents: read` and accesses only the protected release environment. It runs tests before signing, verifies arm64 and the Developer ID team, then signs and notarizes. The publication job checks out the same commit, downloads only this workflow build's named artifact, verifies its exact file set, DMG hash, source and verified tag-object identities, and Accepted status, and re-resolves both the remote tag object and its commit before publishing. Replacing a signed tag with another tag pointing to the same commit fails these checks. Only publication has `contents: write`; its token is the workflow's `GITHUB_TOKEN`. No job persists checkout credentials.

The workflow creates a draft, uploads the three assets, verifies the remote asset names and sizes, rechecks the exact tag object and commit, then publishes. Upload failures leave a draft. A retry can replace assets only in an existing draft bound to the same exact commit. Publication leaves Latest selection to GitHub rather than forcing backfilled versions to Latest. Published releases are immutable to this workflow: retries fail instead of overwriting them. Signing/notarization failures publish nothing; inspect the failed job and Apple's submission in the developer account before retrying. Full reruns create a fresh uniquely named artifact. A retry of only failed publication uses the artifact output of the completed signing job, retained for seven days. Expired artifacts require a full rerun. Runs for the same tag are serialized and never cancelled by newer runs. Restrict manual editing of drafts while a release is running.

Release assets and metadata written with `GITHUB_TOKEN` are not expected to trigger another Actions workflow. Pages has its own main-push/manual trigger, so publication does not rely on a token-created release or tag event. Neither workflow moves branch refs, creates tags, or changes repository visibility. No automatic cleanup deletes tags or releases after failure.

Third-party action entry points are pinned to verified release commits. The hosted OS image labels and installed Xcode remain moving GitHub-maintained environments; `release.json` records the selected Xcode version. The release uses system Apple build/signing tools and adds no build dependencies. Local workflow validation includes actionlint, YAML parsing, bash syntax checks, and ShellCheck. Mocked publication tests cover new releases, draft retries, API failures, changed tags, rejected notarization, corrupt artifacts, upload failures, and unexpected remote assets. Credential-backed notarization still needs a real configured release run.

References: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [GitHub signing on macOS runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications), [GitHub token event behavior](https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow).
