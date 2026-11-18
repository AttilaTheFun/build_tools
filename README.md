# build_tools

The build tools Logan's repositories share (isomer, playground, visor, shireworks): Swift executables a repository
takes through [rules_swift_package_manager](https://github.com/cgrindel/rules_swift_package_manager) at a tagged
version, built from source by Bazel and cached.

**A signer's keys never go through Bazel.** Bazel's client hands its environment to its server (which repository rules
and `--action_env` can read) and, with a build event stream, to BuildBuddy. So a signing job builds `sign` in a step
with no secret in its environment, then runs the binary directly in the next, with the keys in that step's environment
alone:

```sh
# Step 1, no secrets: the binary built, and where it is.
bazel run --script_path="$RUNNER_TEMP/sign" @build_tools//:sign
# Step 2, the release environment's secrets in this step's env alone: the binary itself, not Bazel.
"$RUNNER_TEMP/sign" android --app storybook --pin <sha256> --java <java> --apksigner <apksigner.jar> \
    --key-from-env in.apk out.apk
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
- `sign apple`: next (Developer ID, notarized and stapled, a disk image; an iPhone app with its profiles).
