import "dart:async";
import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:inventree/inventree/app_update_release.dart";
import "package:inventree/widget/app_updates.dart";

void main() {
  final source = Uri.parse("https://updates.example.com/apps/latest.json");
  final payload = utf8.encode("verified update test bytes");
  Map<String, dynamic> manifest() => {
    "schemaVersion": 1,
    "packageId": "inventree.inventree_app.team",
    "version": "0.25.3",
    "buildNumber": 128,
    "sizeBytes": payload.length,
    "minSdk": 24,
    "sha256": sha256.convert(payload).toString(),
    "apkUrl": "Omni-Gears-0.25.3+128.apk",
    "releaseNotes": "App updates",
  };

  Future<AppUpdateRelease?> fetch(
    Map<String, dynamic> data, {
    int installedBuild = 127,
  }) async {
    final client = AppUpdateClient(
      client: MockClient((request) async {
        expect(request.url, source);
        expect(request.followRedirects, isFalse);
        expect(request.headers.containsKey("authorization"), isFalse);
        return http.Response(
          jsonEncode(data),
          200,
          headers: {"content-type": "application/json"},
        );
      }),
    );
    try {
      return await client.latest(
        source,
        installedPackage: "inventree.inventree_app.team",
        installedBuild: installedBuild,
      );
    } finally {
      client.close();
    }
  }

  test(
    "recognises a higher build even when the displayed version is unchanged",
    () async {
      final release = await fetch(manifest());
      expect(release?.buildNumber, 128);
      expect(
        release?.apkUrl.toString(),
        "https://updates.example.com/apps/Omni-Gears-0.25.3+128.apk",
      );
    },
  );

  test("never offers the installed build or a downgrade", () async {
    expect(await fetch(manifest(), installedBuild: 128), isNull);
    expect(await fetch(manifest(), installedBuild: 129), isNull);
  });

  test("rejects updates intended for another package", () async {
    await expectLater(
      fetch(manifest()..["packageId"] = "another.app"),
      throwsFormatException,
    );
  });

  test("rejects insecure, credential-bearing and cross-origin update URLs", () {
    for (final value in [
      "http://updates.example.com/latest.json",
      "https://admin:password@example.com/latest.json",
      "https://example.com/latest.json#section",
      "not a URL",
    ]) {
      expect(() => validateUpdateSource(value), throwsFormatException);
    }
    for (final value in [
      "https://elsewhere.example.com/app.apk",
      "//elsewhere.example.com/app.apk",
      "http://updates.example.com/app.apk",
    ]) {
      expect(
        () => AppUpdateRelease.fromJson(manifest()..["apkUrl"] = value, source),
        throwsFormatException,
      );
    }
  });

  test("rejects malformed, oversized or ambiguous release metadata", () {
    final invalid = <Map<String, dynamic>>[
      {"schemaVersion": 2},
      {"buildNumber": "128"},
      {"buildNumber": 0},
      {"buildNumber": 2100000001},
      {"sizeBytes": 0},
      {"sizeBytes": maxUpdateBytes + 1},
      {"sha256": "invalid"},
      {"minSdk": 1},
      {
        "releaseNotes": ["bad"],
      },
    ];
    for (final replacement in invalid) {
      expect(
        () =>
            AppUpdateRelease.fromJson(manifest()..addAll(replacement), source),
        throwsFormatException,
      );
    }
  });

  test(
    "does not interpret a proxy login page or redirect as an update",
    () async {
      for (final response in [
        http.Response(
          "<html>Sign in</html>",
          200,
          headers: {"content-type": "text/html"},
        ),
        http.Response(
          "",
          302,
          headers: {"location": "https://login.example.com"},
        ),
        http.Response("[]", 200, headers: {"content-type": "application/json"}),
        http.Response(
          "{" + " " * 65536 + "}",
          200,
          headers: {"content-type": "application/json"},
        ),
      ]) {
        final client = AppUpdateClient(
          client: MockClient((_) async => response),
        );
        try {
          await expectLater(
            client.latest(
              source,
              installedPackage: "inventree.inventree_app.team",
              installedBuild: 127,
            ),
            throwsFormatException,
          );
        } finally {
          client.close();
        }
      }
    },
  );

  group("installer downloads", () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp("omni-update-test-");
    });
    tearDown(() async {
      // Recursive removal is restricted to the unique temporary test directory.
      final parent = Directory.systemTemp.absolute.path;
      if (!directory.absolute.path.startsWith(
        "$parent${Platform.pathSeparator}omni-update-test-",
      )) {
        throw StateError("Unexpected test directory");
      }
      await directory.delete(recursive: true);
    });

    AppUpdateClient downloader(List<int> body, {int status = 200}) =>
        AppUpdateClient(
          cacheDirectory: () async => directory,
          client: MockClient((request) async {
            expect(request.followRedirects, isFalse);
            expect(request.headers.containsKey("authorization"), isFalse);
            return http.Response.bytes(body, status);
          }),
        );

    test("streams a verified APK into the app's updater cache", () async {
      final progress = <double>[];
      final file = await downloader(payload).download(
        AppUpdateRelease.fromJson(manifest(), source),
        onProgress: progress.add,
      );
      expect(await file.readAsBytes(), payload);
      expect(file.parent.path.replaceAll("\\", "/"), endsWith("/omni-updates"));
      expect(progress.last, 1);
      expect(
        await directory
            .list(recursive: true)
            .where((entry) => entry.path.endsWith(".part"))
            .isEmpty,
        isTrue,
      );
    });

    test("rejects tampered bytes even when their size is correct", () async {
      final tampered = List<int>.from(payload)..[0] ^= 1;
      await expectLater(
        downloader(
          tampered,
        ).download(AppUpdateRelease.fromJson(manifest(), source)),
        throwsFormatException,
      );
      expect(
        await directory
            .list(recursive: true)
            .where((entry) => entry is File)
            .isEmpty,
        isTrue,
      );
    });

    test("rejects truncated, oversized and redirected downloads", () async {
      for (final body in [
        payload.sublist(1),
        [...payload, 0],
      ]) {
        await expectLater(
          downloader(
            body,
          ).download(AppUpdateRelease.fromJson(manifest(), source)),
          throwsFormatException,
        );
      }
      await expectLater(
        downloader(
          payload,
          status: 302,
        ).download(AppUpdateRelease.fromJson(manifest(), source)),
        throwsFormatException,
      );
      expect(
        await directory
            .list(recursive: true)
            .where((entry) => entry is File)
            .isEmpty,
        isTrue,
      );
    });

    test(
      "cancelled downloads are removed and never offered for installation",
      () async {
        final chunks = Stream<List<int>>.fromIterable([
          payload.sublist(0, 5),
          payload.sublist(5),
        ]);
        final client = AppUpdateClient(
          cacheDirectory: () async => directory,
          client: MockClient.streaming(
            (request, body) async => http.StreamedResponse(chunks, 200),
          ),
        );
        await expectLater(
          client.download(
            AppUpdateRelease.fromJson(manifest(), source),
            onProgress: (_) => client.cancel(),
          ),
          throwsA(isA<UpdateCancelled>()),
        );
        expect(
          await directory
              .list(recursive: true)
              .where((entry) => entry is File)
              .isEmpty,
          isTrue,
        );
      },
    );

    test(
      "a failed new download preserves the previously verified installer",
      () async {
        final original = await downloader(
          payload,
        ).download(AppUpdateRelease.fromJson(manifest(), source));
        await expectLater(
          downloader([1, 2]).download(
            AppUpdateRelease.fromJson(
              manifest()..["buildNumber"] = 129,
              source,
            ),
          ),
          throwsFormatException,
        );
        expect(await original.readAsBytes(), payload);
      },
    );
  });

  testWidgets(
    "update prompt supports a small screen, large text and long release notes",
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final release = AppUpdateRelease.fromJson(
        manifest()
          ..["releaseNotes"] = List.filled(
            30,
            "A new feature is available.",
          ).join("\n"),
        source,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AppUpdateDialog(release: release),
                ),
                child: const Text("Show update"),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text("Show update"));
      await tester.pumpAndSettle();
      expect(find.text("Update available"), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text("Later"));
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdateDialog), findsNothing);
    },
  );
}
