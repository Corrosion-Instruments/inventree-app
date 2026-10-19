## InvenTree App Development

For developers looking to contribute to the project, we use Flutter for app development. The project has been tested in Android Studio (on both Windows and Mac) and also VSCode.

## Prerequisites

To build the app from source, you will need the following tools installed on your system:

- Android Studio or Visual Studio Code (with Flutter and Dart plugins)
- [Flutter Version Management (FVM)](https://fvm.app/) - We use FVM to manage Flutter versions

### iOS Development

For iOS development, you will need a Mac system with XCode installed.

### Java Version

Some versions of Android Studio ship with a built-in version of the Java JDK. However, the InvenTree app requires [JDK 17](https://www.oracle.com/java/technologies/javase/jdk17-archive-downloads.html) to be installed.

If you see any errors related to JDK version mismatch, download and install the correct version of the JDK (from the link above) and update your Android Studio settings to point to the correct JDK location:

```bash
fvm flutter config --jdk-dir /path/to/jdk
```

## Invoke Tasks

We use the [invoke](https://www.pyinvoke.org) to run some core tasks - you will need python and invoke installed on your local system.

## Flutter Version Management (FVM)

This project uses [Flutter Version Management (FVM)](https://fvm.app/) to ensure consistent Flutter versions across development environments and CI/CD pipelines.

For installation instructions, please refer to the [official FVM documentation](https://fvm.app/documentation/getting-started/installation).

Once installed, FVM will automatically use the Flutter version specified in the `.fvmrc` file at the root of the project.

### Visual Studio Code

To set up Visual Studio Code, you will need to make sure the `.vscode` directory exists. Then run `fvm use` to ensure the correct Flutter version is used.

```
mkdir -p .vscode
fvm use
```

#### What happens:
- Downloads SDK if not cached
- Creates `.fvm` directory with SDK symlink
- Updates `.fvmrc` configuration
- Configures IDE settings
- Runs `flutter pub get`


### Android Studio

To set up Android Studio, run `fvm use` to ensure the correct Flutter version is used.

```
fvm use
```

#### What happens:
- Downloads SDK if not cached
- Creates `.fvm` directory with SDK symlink
- Updates `.fvmrc` configuration
- Runs `flutter pub get`

Set Flutter SDK path in Android Studio:

1. Open Android Studio
2. Go to `File` -> `Settings` -> `Languages & Frameworks` -> `Flutter`
3. Set `Flutter SDK path` to `.fvm/flutter_sdk`:

![Setting Flutter SDK path in Android Studio](docs/android_studio_fvm.png)


## Getting Started

Initial project setup (after you have installed all required dev tools) is as follows:

Generate initial translation files:

```
invoke translate
```

Install required flutter packages:
```
fvm flutter pub get
```

You should now be ready to debug on a connected or emulated device!

## Troubleshooting

### Flutter Doctor

If you're experiencing issues with the development environment, run Flutter Doctor to diagnose problems:

```bash
fvm flutter doctor -v
```

This will check your Flutter installation and identify any issues with your setup. Common issues include:

- Missing Android SDK components
- iOS development tools not properly configured
- Missing dependencies

Fix any identified issues before proceeding with development.


## Building Release Versions

Building release versions for target platforms (either android or iOS) is simplified using invoke:

### Android

Build Android release:

```
invoke android
```

### iOS

Build iOS release:

```
invoke ios
```

## Private Android team distribution

Android release builds use application ID `inventree.inventree_app.team` and
launcher name **Omni Gears**, so they can coexist with the public app and
development installs. Each team installation needs its own server profile.
The previous **InvenTree Team** release uses the same application ID and signing
key; installing Omni Gears over that release keeps its local settings.

Release signing is configured through the ignored `android/key.properties` file.
On the current build machine, the original keystore and a backup of that file
are held in `%USERPROFILE%\.inventree-team-signing\inventree-app`. Keep an
encrypted company backup of the entire signing directory. Never upload it to
the team's APK download folder or commit signing credentials to Git. If moving
to another build machine, restore these files and update `storeFile` in
`android/key.properties` to the restored keystore path. Future updates must
use the original key.

Build and verify an installer from PowerShell:

```powershell
.\scripts\build-team-android.ps1
```

The script checks the APK signature, team application ID, launcher name, and
release mode, then places the versioned APK, SHA256 checksum, and installation
instructions in `build/team-release`. Share those files through an authenticated
company folder. Android may ask users to allow installation from their browser
or file manager; managed devices may need an administrator's installation policy.

For an update, use a build number greater than the previously distributed one:

```powershell
.\scripts\build-team-android.ps1 -BuildNumber 129
```

Install updates over the existing team app to retain local settings. The
updater-enabled release must first be installed over the previous Teams APK.
The app still needs access to an
InvenTree server and individual user accounts; downloading the installer does
not grant access to inventory data.

## In-app updates and Dokploy hosting

Omni Gears checks its own release feed on launch and when returning to the app
(at most once per 15 minutes in a running session). It offers a newer Android
build with an **Update** button, downloads into private app cache, checks the
size and SHA256 digest, then asks Android to install it. Native validation also
checks the package, increasing build number, minimum Android version and exact
installed signing certificate. Android's user confirmation remains required.
Downloads use normal certificate validation, with no inventory credentials or
inventory-server certificate exceptions. Cancelling removes partial downloads.

Until a hosting address is chosen, checks are disabled. Set the full HTTPS URL
ending in `/latest.json` through **Settings > About > App updates > Update source**.
Alternatively, embed the address into a release so staff need no setup:

```powershell
.\scripts\build-team-android.ps1 -UpdateFeedUrl 'https://downloads.example.com/latest.json' -ReleaseNotes 'Describe the changes for staff here.'
```

The example domain is a placeholder. Pass the same real feed address on every
future build. A saved on-device update address overrides the build default;
an empty saved address disables checks. The source can be corrected without
reinstalling the app. Staff can check immediately from **About > App updates**.
The original InvenTree GitHub release checker has been replaced.

Every build creates `build/team-release/latest.json` plus a matching APK and
copies these into `build/update-server/public`. The manifest uses a relative
APK filename, so it can be hosted with the manifest on any chosen HTTPS origin.
The updater rejects cross-origin URLs, redirects, login pages, malformed feeds,
downloads over 512 MiB, tampered content and old build numbers. Serve the feed
and APK directly; a Teams sharing page or interactive SSO page is not a feed.

To host on Dokploy:

1. Copy `build/update-server/public` to a persistent server directory such as
   `/opt/omni-gears-updates/public`. Copy `deploy/app-updates/nginx.conf` to
   `/opt/omni-gears-updates/nginx.conf`. Neither contains signing keys.
2. Create a **Docker Compose** service in Dokploy using the contents of
   `deploy/app-updates/compose.yaml`.
3. Set its environment variables to the absolute server paths:
   `OMNI_UPDATE_FILES_PATH=/opt/omni-gears-updates/public` and
   `OMNI_UPDATE_CONFIG_PATH=/opt/omni-gears-updates/nginx.conf`.
4. In Dokploy's Domains tab, configure the chosen hostname, service
   `omni-gears-updates`, container port **8080**, and HTTPS. Deploy.
5. Verify `/latest.json` and its APK are downloadable on a team phone, then set
   that HTTPS feed URL in the app or embed it using the release command above.

For internal-only downloads, restrict access at the network/VPN layer and ensure
phones use the correct office DNS. The supplied server is a read-only download
endpoint and does not add user login. Do not expose it publicly if your policy
requires staff-only access. TLS must be trusted by the phone; never disable
certificate verification for the update endpoint. Dokploy handles TLS termination.

For each release, test the APK on a phone, copy the versioned APK to the server
first, and atomically replace `latest.json` last (upload as `latest.json.new`,
then rename it). Keep older APKs for devices finishing a download. Nginx does
not cache the feed; versioned APKs may be cached. The persistent bind mount
means future releases need no container rebuild or redeploy. Publishing a
manifest to the server is the release step; building locally does not publish it.

Verify changes with `flutter test test/app_update_test.dart`, `dart analyze`,
and the signed release build. Before rollout, test installation on a real phone:
use a genuinely newer build signed with the original key, verify Android's
install-permission flow, update confirmation, and retained server/login settings.
