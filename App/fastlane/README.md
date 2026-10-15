fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

### bump_build_number

```sh
[bundle exec] fastlane bump_build_number
```

Set the build number to one above the latest iOS or macOS TestFlight build

----


## iOS

### ios build

```sh
[bundle exec] fastlane ios build
```

Archive and export an App Store .ipa

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Push a new beta build to TestFlight

----


## Mac

### mac build

```sh
[bundle exec] fastlane mac build
```

Archive and export an App Store .pkg

### mac beta

```sh
[bundle exec] fastlane mac beta
```

Push a new beta build to TestFlight

### mac developer_id

```sh
[bundle exec] fastlane mac developer_id
```

Archive, export and notarize a Developer ID .app for direct download

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
