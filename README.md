# build_tools

The build tools Logan's repositories share (isomer, playground, visor, shireworks): Swift executables a repository
takes through [rules_swift_package_manager](https://github.com/cgrindel/rules_swift_package_manager) at a tagged
version and runs with Bazel, built from source and cached:

```sh
bazel run @build_tools//:sign -- android --app storybook --pin <sha256> --java <java> --apksigner <apksigner.jar> \
    --key-from-env in.apk out.apk
```

## sign

Signs a build with its release keys, in its CI job. Keys come from the job's environment (`--key-from-env`: a public
repository's GitHub environment secrets, each read once and unset) or from a folder on a tmpfs (`--keys`: Shireworks'
secret service), are written to a private tmpfs folder alone, are never on a command line, and are removed however the
tool ends.

- `sign android`: an APK signed with APK Signature Schemes v2 and v3 by the repository's own pinned apksigner, then
  verified as Android verifies it, and refused unless its one certificate is the pinned one.
- `sign apple`: next (Developer ID, notarized and stapled, a disk image; an iPhone app with its profiles).
