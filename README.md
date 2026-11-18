# build_tools

The build tools Logan's repositories share (isomer, playground, visor, shireworks): Swift executables a repository
takes through [rules_swift_package_manager](https://github.com/cgrindel/rules_swift_package_manager) at a tagged
version, built from source by Bazel and cached.

**A signer's keys never go through Bazel.** Bazel's client hands its environment to its server (which repository rules
and `--action_env` can read) and, with a build event stream, to BuildBuddy. So a signing job builds `sign` in a step
with no secret in its environment, then runs the binary directly in the next, with the keys in that step's environment
alone:

```sh
# Step 1, no secrets: the binary built, and where it is (the binary itself, not `bazel run`'s wrapper script, which
# sets BUILD_WORKSPACE_DIRECTORY as `bazel run` does).
bazel build @build_tools//:sign
echo "SIGN=$PWD/$(bazel cquery --output=files @build_tools//:sign 2>/dev/null)" >> "$GITHUB_ENV"
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
- `sign apple`: Apple apps with no Mac, by the repository's own pinned rcodesign (and rules_applecross' `dmg`). Ported
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
