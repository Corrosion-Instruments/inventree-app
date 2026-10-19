import "package:flutter/foundation.dart";
import "package:package_info_plus/package_info_plus.dart";

import "package:inventree/inventree/app_update_release.dart";
import "package:inventree/preferences.dart";

const String defaultUpdateSource = String.fromEnvironment(
  "OMNI_UPDATE_FEED_URL",
);
const String _updateSourcePreference = "omniUpdateFeedUrl";

class UpdateChecker extends ChangeNotifier {
  factory UpdateChecker() => _instance;
  UpdateChecker._();
  static final UpdateChecker _instance = UpdateChecker._();

  String source = defaultUpdateSource;
  AppUpdateRelease? release;
  bool checking = false;
  bool checked = false;
  String error = "";
  DateTime? _lastAttempt;

  bool get configured => source.isNotEmpty;
  bool get newVersionAvailable => release != null;

  Future<void> loadConfiguration() async {
    source =
        (await InvenTreeSettingsManager().getValue(
                  _updateSourcePreference,
                  defaultUpdateSource,
                )
                as String)
            .trim();
    notifyListeners();
  }

  Future<void> setSource(String value) async {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) validateUpdateSource(trimmed);
    await InvenTreeSettingsManager().setValue(_updateSourcePreference, trimmed);
    source = trimmed;
    release = null;
    checked = false;
    error = "";
    _lastAttempt = null;
    notifyListeners();
  }

  Future<void> checkForUpdate({bool force = false}) async {
    if (checking) return;
    checking = true;
    final client = AppUpdateClient();
    try {
      await loadConfiguration();
      if (!configured ||
          (!force &&
              _lastAttempt != null &&
              DateTime.now().difference(_lastAttempt!) <
                  const Duration(minutes: 15))) {
        return;
      }
      _lastAttempt = DateTime.now();
      error = "";
      final checkedSource = source;
      final info = await PackageInfo.fromPlatform();
      final candidate = await client.latest(
        validateUpdateSource(checkedSource),
        installedPackage: info.packageName,
        installedBuild: int.parse(info.buildNumber),
      );
      if (source == checkedSource) {
        release = candidate;
        checked = true;
      }
    } catch (_) {
      release = null;
      checked = false;
      error =
          "Couldn't check for updates. Check your connection and update address, then try again.";
    } finally {
      client.close();
      checking = false;
      notifyListeners();
    }
  }
}
