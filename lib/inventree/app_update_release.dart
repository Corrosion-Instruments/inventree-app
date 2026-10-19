import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:crypto/crypto.dart";
import "package:http/http.dart" as http;
import "package:path_provider/path_provider.dart";
import "package:path/path.dart" as path;

const int maxUpdateBytes = 512 * 1024 * 1024;

Uri validateUpdateSource(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != "https" ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException("Enter a valid HTTPS update address.");
  }
  return uri;
}

class AppUpdateRelease {
  AppUpdateRelease.fromJson(Map<String, dynamic> json, Uri source) {
    validateUpdateSource(source.toString());
    if (json["schemaVersion"] != 1 ||
        json["packageId"] is! String ||
        json["version"] is! String ||
        json["buildNumber"] is! int ||
        json["sizeBytes"] is! int ||
        json["minSdk"] is! int ||
        json["sha256"] is! String ||
        json["apkUrl"] is! String) {
      throw const FormatException("Invalid update information.");
    }
    packageId = json["packageId"] as String;
    version = json["version"] as String;
    buildNumber = json["buildNumber"] as int;
    sizeBytes = json["sizeBytes"] as int;
    minSdk = json["minSdk"] as int;
    checksum = (json["sha256"] as String).toLowerCase();
    apkUrl = validateUpdateSource(
      source.resolve(json["apkUrl"] as String).toString(),
    );
    final notes = json["releaseNotes"] ?? "";
    if (packageId.isEmpty ||
        !RegExp(r"^[0-9A-Za-z.+_-]{1,64}$").hasMatch(version) ||
        buildNumber < 1 ||
        buildNumber > 2100000000 ||
        sizeBytes < 1 ||
        sizeBytes > maxUpdateBytes ||
        minSdk < 24 ||
        !RegExp(r"^[a-f0-9]{64}$").hasMatch(checksum) ||
        apkUrl.origin != source.origin ||
        !apkUrl.path.toLowerCase().endsWith(".apk") ||
        notes is! String ||
        notes.length > 8000) {
      throw const FormatException("Invalid update information.");
    }
    releaseNotes = notes;
  }

  late final String packageId;
  late final String version;
  late final int buildNumber;
  late final int sizeBytes;
  late final int minSdk;
  late final String checksum;
  late final Uri apkUrl;
  late final String releaseNotes;
}

class UpdateCancelled implements Exception {}

/// Inventory credentials and relaxed TLS policies must never be used for updates.
class AppUpdateClient {
  AppUpdateClient({
    http.Client? client,
    Future<Directory> Function()? cacheDirectory,
  }) : _client = client ?? http.Client(),
       _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  final http.Client _client;
  final Future<Directory> Function() _cacheDirectory;
  bool _cancelled = false;

  void close() => _client.close();
  void cancel() {
    _cancelled = true;
    close();
  }

  void _checkCancelled() {
    if (_cancelled) throw UpdateCancelled();
  }

  Future<AppUpdateRelease?> latest(
    Uri source, {
    required String installedPackage,
    required int installedBuild,
  }) async {
    validateUpdateSource(source.toString());
    final request = http.Request("GET", source)
      ..followRedirects = false
      ..headers["Accept"] = "application/json"
      ..headers["Cache-Control"] = "no-cache";
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 15));
    final contentType = (response.headers["content-type"] ?? "")
        .split(";")
        .first
        .trim()
        .toLowerCase();
    if (response.statusCode != 200 ||
        !(contentType == "application/json" || contentType.endsWith("+json"))) {
      throw const FormatException(
        "The update server did not return update information.",
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      if (bytes.length + chunk.length > 65536) {
        throw const FormatException("Update information is too large.");
      }
      bytes.add(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (data is! Map<String, dynamic>) {
      throw const FormatException("Invalid update information.");
    }
    final release = AppUpdateRelease.fromJson(data, source);
    if (release.packageId != installedPackage) {
      throw const FormatException("This update is for a different app.");
    }
    return release.buildNumber > installedBuild ? release : null;
  }

  Future<File> download(
    AppUpdateRelease release, {
    void Function(double)? onProgress,
  }) async {
    File? partial;
    IOSink? sink;
    try {
      _checkCancelled();
      final directory = Directory(
        path.join((await _cacheDirectory()).path, "omni-updates"),
      );
      await directory.create(recursive: true);
      _checkCancelled();
      final destination = File(
        path.join(
          directory.path,
          "${release.buildNumber}-${release.checksum}.apk",
        ),
      );
      partial = File("${destination.path}.part");
      final request = http.Request("GET", release.apkUrl)
        ..followRedirects = false;
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 ||
          (response.contentLength != null &&
              response.contentLength != release.sizeBytes)) {
        throw const FormatException(
          "The update download is incomplete or unavailable.",
        );
      }
      sink = partial.openWrite();
      int received = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        _checkCancelled();
        received += chunk.length;
        if (received > release.sizeBytes) {
          throw const FormatException(
            "The update download has an unexpected size.",
          );
        }
        sink.add(chunk);
        onProgress?.call(received / release.sizeBytes);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      _checkCancelled();
      if (received != release.sizeBytes ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              release.checksum) {
        throw const FormatException(
          "Update verification failed. Please download it again.",
        );
      }
      _checkCancelled();
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      partial = null;
      // Remove only old APKs owned by this updater, inside its private cache.
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File &&
            !path.equals(entry.path, destination.path) &&
            RegExp(
              r"^\d+-[a-f0-9]{64}\.apk$",
            ).hasMatch(path.basename(entry.path))) {
          try {
            await entry.delete();
          } on FileSystemException {
            /* An installer may still have it open. */
          }
        }
      }
      return destination;
    } catch (_) {
      if (_cancelled) throw UpdateCancelled();
      rethrow;
    } finally {
      await sink?.close();
      if (partial != null && await partial.exists()) await partial.delete();
      close();
    }
  }
}
