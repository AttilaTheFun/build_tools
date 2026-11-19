# build_tools

The build tools Logan's repositories share (isomer, playground, visor, shireworks): Swift executables a repository
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

- `sign android`: an APK signed with APK Signature Schemes v2 and v3 by the repository's own pinned apksigner, then
  verified as Android verifies it, and refused unless its one certificate is the pinned one.
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
  - An iPhone app's .ipa: its extensions, then the app, each with its own profile of `--ipa-kind` (development, the
    default, signed with the development identity; ad-hoc, app-store or enterprise, with the distribution one) and
    its entitlements made the profile's; every other piece of code with the same identity, deepest first.
  - `--variant Production` sets each app's BuildVariant first (a published release promoting its Alphas); `--app
    <App>` names outputs `<App>-<version>-<platform>.<ext>`; `--describe <file>` appends each output's builds.json
    line (file, app, bundleID, platform, version, buildNumber, variant, size, sha256) as a line of JSON.
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
