import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:inventree/app_brand.dart";
import "package:inventree/inventree/app_update_release.dart";
import "package:inventree/inventree/update_check.dart";

const _installer = MethodChannel("omni_gears/app_updates");
bool _updateDialogOpen = false;
int? _promptedBuild;

Future<void> checkForAppUpdates(
  BuildContext context, {
  bool manual = false,
}) async {
  if (!Platform.isAndroid || _updateDialogOpen) return;
  final checker = UpdateChecker();
  await checker.checkForUpdate(force: manual);
  if (!context.mounted ||
      !checker.configured ||
      checker.checking ||
      _updateDialogOpen) {
    return;
  }
  final release = checker.release;
  if (release == null) {
    if (manual) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            checker.error.isEmpty
                ? "You're up to date"
                : "Couldn't check for updates",
          ),
          content: Text(
            checker.error.isEmpty
                ? "$APP_DISPLAY_NAME is running the latest available version."
                : checker.error,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("OK"),
            ),
          ],
        ),
      );
    }
    return;
  }
  if (!manual && _promptedBuild == release.buildNumber) return;
  _updateDialogOpen = true;
  _promptedBuild = release.buildNumber;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AppUpdateDialog(release: release),
    );
  } finally {
    _updateDialogOpen = false;
  }
}

Future<void> configureAppUpdates(BuildContext context) async {
  final checker = UpdateChecker();
  await checker.loadConfiguration();
  if (!context.mounted) return;
  final controller = TextEditingController(text: checker.source);
  final key = GlobalKey<FormState>();
  bool saving = false;
  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Update source"),
          content: Form(
            key: key,
            child: TextFormField(
              controller: controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: "Update address",
                helperText:
                    "Use the HTTPS address provided by your administrator. Leave empty to disable update checks.",
                helperMaxLines: 4,
              ),
              validator: (value) {
                if ((value ?? "").trim().isEmpty) return null;
                try {
                  validateUpdateSource(value!);
                  return null;
                } on FormatException catch (error) {
                  return error.message;
                }
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (!key.currentState!.validate()) return;
                      setDialogState(() => saving = true);
                      try {
                        await checker.setSource(controller.text);
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } catch (_) {
                        if (dialogContext.mounted) {
                          setDialogState(() => saving = false);
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            const SnackBar(
                              content: Text(
                                "Couldn't save the update address.",
                              ),
                            ),
                          );
                        }
                      }
                    },
              child: const Text("Save"),
            ),
          ],
        ),
      ),
    );
  } finally {
    controller.dispose();
  }
}

class AppUpdatesTile extends StatefulWidget {
  const AppUpdatesTile({super.key});
  @override
  State<AppUpdatesTile> createState() => _AppUpdatesTileState();
}

class _AppUpdatesTileState extends State<AppUpdatesTile> {
  @override
  void initState() {
    super.initState();
    UpdateChecker().loadConfiguration();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: UpdateChecker(),
      builder: (context, _) {
        final checker = UpdateChecker();
        final subtitle = checker.checking
            ? "Checking for updates…"
            : !checker.configured
            ? "Set up an update source"
            : checker.newVersionAvailable
            ? "Version ${checker.release!.version} is available"
            : checker.error.isNotEmpty
            ? "Couldn't check for updates. Tap to retry."
            : checker.checked
            ? "You're up to date"
            : "Check for a new version";
        return ListTile(
          leading: const Icon(Icons.system_update),
          title: const Text("App updates"),
          subtitle: Text(subtitle),
          onTap: checker.checking
              ? null
              : () async {
                  if (!checker.configured) await configureAppUpdates(context);
                  if (context.mounted && checker.configured) {
                    await checkForAppUpdates(context, manual: true);
                  }
                },
          trailing: IconButton(
            tooltip: "Update source",
            onPressed: checker.checking
                ? null
                : () => configureAppUpdates(context),
            icon: const Icon(Icons.settings_outlined),
          ),
        );
      },
    );
  }
}

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({super.key, required this.release});
  final AppUpdateRelease release;
  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  AppUpdateClient? _download;
  File? _apk;
  double _progress = 0;
  bool _busy = false;
  bool _needsPermission = false;
  String _error = "";

  @override
  void dispose() {
    _download?.cancel();
    super.dispose();
  }

  Future<void> _update() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = "";
      _needsPermission = false;
    });
    try {
      if (_apk == null) {
        _download = AppUpdateClient();
        _apk = await _download!.download(
          widget.release,
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
        );
        _download = null;
      }
      if (!mounted) return;
      if (await _installer.invokeMethod<bool>("canInstallPackages") != true) {
        if (!mounted) return;
        setState(() {
          _needsPermission = true;
          _busy = false;
        });
        await _installer.invokeMethod<void>("openInstallSettings");
        return;
      }
      if (!mounted) return;
      await _installer.invokeMethod<void>("installApk", {
        "path": _apk!.path,
        "buildNumber": widget.release.buildNumber,
      });
      if (mounted) Navigator.pop(context);
    } on UpdateCancelled {
      // The Cancel button closes the dialog; the partial file is removed.
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.message ?? "Couldn't open the update installer.",
        );
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              "Couldn't download the update. Check your connection and try again.",
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.release;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(_busy ? "Downloading update" : "Update available"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "$APP_DISPLAY_NAME ${release.version} • Build ${release.buildNumber}",
              ),
              const SizedBox(height: 8),
              Text(
                "${(release.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB",
              ),
              if (release.releaseNotes.isNotEmpty && !_busy) ...[
                const SizedBox(height: 16),
                Text(release.releaseNotes),
              ],
              const SizedBox(height: 16),
              if (_busy) ...[
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 8),
                Text(
                  _progress >= 1
                      ? "Verifying update…"
                      : "${(_progress * 100).floor()}% downloaded",
                ),
              ] else if (_needsPermission)
                const Text(
                  "Allow Omni Gears to install updates in Android settings, then return here and tap Install update.",
                )
              else
                const Text(
                  "Your settings will be kept. Android will ask you to confirm the update.",
                ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (_busy) {
                _download?.cancel();
                setState(() => _busy = false);
              }
              Navigator.pop(context);
            },
            child: Text(_busy ? "Cancel" : "Later"),
          ),
          FilledButton(
            onPressed: _busy ? null : _update,
            child: Text(_apk == null ? "Update" : "Install update"),
          ),
        ],
      ),
    );
  }
}
