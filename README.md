# build_tools

The build tools Logan's repositories share (isomer, playground, visor, shireworks, images): Swift executables a repository
takes through [rules_swift_package_manager](https://github.com/cgrindel/rules_swift_package_manager) at a tagged
version, built from source by Bazel and cached.

**A signer's keys never go through Bazel.** Bazel's client hands its environment to its server (which repository rules
and `--action_env` can read) and, with a build event stream, to BuildBuddy. So a signing job builds `sign` in a step
with no secret in its environment, then runs the binary directly in the next, with the keys in that step's environment
alone:

```sh
# Step 1, no secrets: the binary built, and where it is. Through rules_swift_package_manager the label is
# @swiftpkg_build_tools//:sign; cquery names two files (the binary, `sign.rspm.__impl`, and a link to it), relative to
# the execution root. The binary itself, not `bazel run`'s wrapper script, which sets BUILD_WORKSPACE_DIRECTORY as
# `bazel run` does.
bazel build @swiftpkg_build_tools//:sign
echo "SIGN=$(bazel info execution_root)/$(bazel cquery --output=files @swiftpkg_build_tools//:sign 2>/dev/null | grep '__impl$' | head -1)" >> "$GITHUB_ENV"
# Step 2, the release environment's secrets in this step's env alone: the binary run directly.
"$SIGN" android --app storybook --pin <sha256> --java <java> --apksigner <apksigner.jar> --key-from-env in.apk out.apk
```

`sign` refuses `--key-from-env` when `bazel run` runs it (`BUILD_WORKSPACE_DIRECTORY` set), so the one-step form
can't be used by accident.

## sign

Signs a build with its release keys, in its CI job. Keys come from the job's environment (`--key-from-env`: a public
repository's GitHub environment secrets, each read once and unset) or from a folder on a tmpfs (`--keys`: Shireworks'
secret service), are written to a private tmpfs folder alone, are never on a command line, and are removed however the
tool ends.

- `sign android` (with `--aapt2 <the repository's aapt2>`, `--describe` and `--builds` as `sign apple`'s: its
  package, versionName, versionCode, label or `--name`, `--variant`, `"urlSchemes": []`): an APK signed with APK Signature Schemes v2 and v3 by the repository's own pinned apksigner, then
  verified as Android verifies it, and refused unless its one certificate is the pinned one. `--out <folder>` in place
  of the output path names it `<name or label>-<versionName>-android.apk` from the APK itself (with `--aapt2`);
  `--skip-missing-keys` skips, saying so as `sign apple` does, when its key isn't here.
- `sign apple` (its options below; `--ipa-kind ad-hoc,development` tries each kind in order, the first with its
  identity here and a profile for every bundle; `--skip-missing-keys` skips, saying so on standard error and in the
  job's summary, a package whose platform's keys aren't here; apple-profiles is needed for an iPhone app, and for a
  Mac app only where its entitlements need a profile): Apple apps with no Mac, by the repository's own pinned rcodesign (and rules_applecross' `dmg`). Ported
  from shireworks' tools/ci/apple_sign.sh and apple_profiles.py.
  - A Mac app's .zip (one .app at its top): Developer ID (hardened runtime, a timestamp), its Developer ID profile
    embedded and its entitlements made the profile's when there's one for it, notarized and stapled; with `--dmg
    <dmg>`, its disk image beside it (the app and an Applications link), signed, notarized and stapled too. A Mac app
    asking for an entitlement only a profile allows (keychain groups, push, a `group.*` app group), with no profile
    for it, is refused: macOS would kill it at launch, and notarizing doesn't catch that.
  - `--mac-kind development`: a Mac app's .zip signed with the Apple Development identity and its Mac development
    profile (always embedded; it names the Macs the build runs on), its entitlements made the profile's, not
    notarized and with no disk image: for an entitlement Apple provisions for development and the App Store but not
    Developer ID (Sensitive Content Analysis). Its keys are apple-development-p12 and -password, and apple-profiles.
  - An iPhone app's .ipa: its extensions, then the app, each with its own profile of `--ipa-kind` (development, the
    default, signed with the development identity; ad-hoc, app-store or enterprise, with the distribution one) and
    its entitlements made the profile's; every other piece of code with the same identity, deepest first.
  - `--variant Production` sets each app's BuildVariant first (a published release promoting its Alphas); `--app
    <App>` names outputs `<App>-<version>-<platform>.<ext>`; `--describe <file>` appends each output's builds.json
    line as a line of JSON, and `--builds <builds.json>` merges it into that array (an earlier line for the same file
    replaced): file, app, bundleID, platform, version, buildNumber, variant (the bundle's BuildVariant, else Alpha),
    commit (`--commit`, else GITHUB_SHA), executableUUID (its executable's LC_UUID, the arm64 slice of a fat one),
    size, sha256, urlSchemes where it has some, and for a Mac app's .zip `icon` (`<App>-<version>-icon.png`, the
    largest PNG in its .icns, written beside it; its disk image's line has none), as shireworks' docs/RELEASE_ASSETS.md
    has them. builds.json is written pretty-printed, its keys sorted.
  - What the build left out, stamped into the outer app just before it's signed (a build on runners that hold no
    secrets: the signing job has them): `--add-infoplist <file.json>`, a JSON object whose values are strings or
    arrays of strings, each key once, merged into its Info.plist (a key already there with another value is refused,
    and so is BuildVariant, `--variant`'s); `--add-groups <file.json>`, `{"app": [...], "keychain": [...]}`: app
    groups appended once to `com.apple.security.application-groups` (made where there's none), keychain groups
    (`<TEAM>.<group>`) appended last to `keychain-access-groups`, after the app's own (where it has none, its
    profile's `<prefix>.<bundle id>` first, so the app still saves to its own group by default). Files, never the
    command line, where another process or a step echoing it would see them. A value may hold
    `$(AppIdentifierPrefix)`, which is filled with each top-level app's chosen profile's prefix and its dot
    (`TEAM.`), as Xcode fills it, so the signing job needs no team of its own; a Mac app with no profile using it is
    refused. The groups go in before its profile is
    checked, and one the profile doesn't allow is refused. Only the outer app gets them, never its extensions, and
    nothing of their values is printed: a refusal says which file and how many, never what.
  - `--unsigned` (an experiment's, from a branch with no keys): each Apple package copied out as built, named and
    described the same way, not signed or stamped: its line's variant `AdHoc` and `"signed": false`, which Applications
    lists only in an experiment's release (`adhoc-…`). It runs no rcodesign, so it needs no `--rcodesign`.
  - Keys by their secrets' names (`--keys`, Shireworks' secret service), or from these variables (`--key-from-env`):

    | Secret | Variable | Needed for |
    | --- | --- | --- |
    | apple-developer-id-p12, -password | APPLE_DEVELOPER_ID_P12 (base64), APPLE_DEVELOPER_ID_PASSWORD | a Mac app |
    | apple-notary-key, -key-id, apple-notary-issuer | APPLE_NOTARY_KEY (the .p8's text), APPLE_NOTARY_KEY_ID, APPLE_NOTARY_ISSUER | a Mac app |
    | apple-development-p12, -password | APPLE_DEVELOPMENT_P12 (base64), APPLE_DEVELOPMENT_PASSWORD | `--ipa-kind development` |
    | apple-distribution-p12, -password | APPLE_DISTRIBUTION_P12 (base64), APPLE_DISTRIBUTION_PASSWORD | ad-hoc, app-store, enterprise |
    | apple-profiles (-2 … -9) | APPLE_PROFILES (_2 … _9): a .tar or .tar.gz of the profiles, base64 | either |

    A password-less .p12 has no password secret. A .p12 is as Keychain Access exports one (3DES): rcodesign can't
    open OpenSSL 3's default, so one re-wrapped needs `-legacy`. Needs unzip, zip, tar and openssl on PATH.

- `sign team --keys <folder> --bundle <id>`: the team of the bundle's profiles in the keys' apple-profiles, printed
  and nothing else (a build stamps the team's prefix into its Info.plist, for the shared sign-in's keychain group,
  with no team id in the repository).

## release

A release's steps in its CI job, ported from shireworks' version_from_tags.sh, check_version_line.sh,
draft_release.sh and attach_release.sh. It talks to GitHub's REST API itself (no `gh`), with the job's token
(`GH_TOKEN`, else `GITHUB_TOKEN`) and `GITHUB_REPOSITORY`; the commit is `GITHUB_SHA` unless given.

- `release version <Info.plist>… [--build-number <Info.plist>]… [--output "$GITHUB_OUTPUT"]`: the build's version,
  `MAJOR.MINOR.N`, the first Info.plist's committed line (`MAJOR.MINOR.0`) with N one past the highest of the line's
  releases and tags, or the one this commit already has. It's stamped into each Info.plist's
  CFBundleShortVersionString (and `--build-number`'s CFBundleVersion) as text, the rest of the file as it was, and
  printed (and written as `version=` to `--output`).
- `release check-line <version>`: refused (`::error::`, exit 1) when the version's line already has a production
  release: the committed line moves on first.
- `release draft <version> --kind prerelease|release --notes <notes.md> --app <App>`: the draft release `v<version>`,
  "<App> <version>", at the commit; the draft of that tag brought up to date if there is one.
- `release attach <tag> <folder>`: the folder's files attached to the release (one of the same name replaced), the
  release waited for a minute if it isn't listed yet, and `builds.json` last; a folder without it may hold only the
  proof (`proof.zip`, `proof-diff.json`).

## ci-bazel

Bazel in a CI container, with Nimbus' settings for the runner: what each private repository's
`tools/ci/container_build.sh` was (nimbus, shireworks, overcast, images, github_drive carried copies). Builds in a Linux
container only. The exit status is Bazel's.

- `ci-bazel [--bazelrc <file>] <build|test|…> <bazel arguments…>` runs `bazel --bazelrc=<rc> <verb> --keep_going
  <arguments>` in the current folder (the checkout). Bazel's own options go straight through (`--noremote_upload_local_results`,
  `--compilation_mode=opt`). The log says the container's CPUs and memory before, and how long the build took and the
  container's peak memory (cgroup v2's `memory.peak`) after: what sizes CI's runners.
- `ci-bazel [--bazelrc <file>] package <folder> <bazel arguments…>` builds, then copies the targets' files into
  `<folder>`, which must be inside the checkout (its files are replaced; its folders stay): what a job signs and
  publishes. The arguments' options (words that start with `-`, each in the one-word form `--name=value`) apply to the
  build and to finding its files (`bazel info execution_root`, `bazel cquery --output=files`); the other words are the
  targets, one union for cquery.
- **The bazelrc** comes from Nimbus: the tool runs `nimbus job bazel-config` (the runner's own
  `/opt/nimbus/bin/nimbus`, nimbus#234, from Nimbus' next release) in the checkout and takes the path it prints, one
  line on standard output. Nimbus writes `.ci/downloader.cfg` and `.ci/nimbus.bazelrc` there (keep `.ci` out of git).
  The bazelrc holds `common --downloader_config=<path>`, which sends the Xcode SDK and rules_applecross' ported tools to
  the server's files (no repository pins their SHA-256), `build --config=apple_on_linux` (given twice, Bazel only
  warns), and under 8 GB of memory `build --worker_max_instances=SwiftCompile=1 --jobs=2` and
  `startup --host_jvm_args=-Xmx1g`: startup options in the file, so `--bazelrc=` is all Bazel needs. `--bazelrc <file>`
  names one instead (Nimbus' command is only asked without it).
- Like `sign`, it is built by Bazel in a step of its own, with no secret in the environment, and run directly.

## Pinned tools

`sign` runs the repository's own pinned tools, never one it downloads. These are the versions it's tested with
(SHA-256 of each release asset):

| Tool | Release | linux aarch64 | linux x86_64 |
| --- | --- | --- | --- |
| rcodesign | apple-platform-rs `apple-codesign/0.29.0`, `apple-codesign-0.29.0-<arch>-unknown-linux-musl.tar.gz` | `4af92c87ddf52f5f2d1258a3b4e56c7dcb8f1b2468df744976c5f139e031961f` | `dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002` |
| dmg | rules_applecross `ported-tools-0.0.92`, `dmg-linux-<arch>.tar.zst` | `e902f3beb581aee24796084d2e2284241e35540a95230e01f5c1899ee61c4d52` | `67ee77b978b2b7b0875c9201bb9b09e5a5f716a49450bc53c804a7e2db4866b9` |

Its dependencies are version ranges (swift-crypto 3.10 up to 6, argument-parser and subprocess from their pinned
minors), so a repository's own graph resolves them.

A statically linked `sign` (rules_swift's default on Linux) writes property lists itself (PlistXML), never through
Foundation's bridging, which can't write a Bool statically linked.

## CI

Pull requests and main's commits are built and tested on Linux alone (`.github/workflows/ci.yml`): Apple runners
only at release verification (Logan, 2026-11-13). A release (`release.yml`) builds and tests on Linux and on a Mac
before it's proposed.
