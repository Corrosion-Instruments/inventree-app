import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:inventree/api.dart";
import "package:inventree/inventree/image_gallery.dart";
import "package:inventree/widget/image_gallery.dart";

Map<String, dynamic> row(int pk, String? image, {String? name}) => {
  "pk": pk,
  "image": image,
  "thumbnail": image == null ? "/static/blank.png" : "$image.thumb.png",
  "name": name ?? "Part $pk",
  "IPN": "IPN-$pk",
  "description": "Description $pk",
};

Future<List<GalleryImage>> fixture() => loadGalleryImages(
  request: (url, params) async => APIResponse(
    statusCode: 200,
    data: [
      row(1, "/media/part-z.jpg", name: "Supplier part"),
      row(2, "/media/real-photo.jpg", name: "GPS Module"),
      row(3, "/media/real-photo.jpg", name: "Shared photo part"),
    ],
  ),
);

Widget app({
  Future<List<GalleryImage>> Function()? load,
  Future<void> Function(BuildContext, int)? openPart,
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: textScaler),
    child: child!,
  ),
  home: ImageGalleryWidget(
    loadImages: load ?? fixture,
    imageBuilder: (source) =>
        Center(child: Text(source, key: ValueKey(source))),
    openPart: openPart,
  ),
);

void main() {
  test(
    "groups shared images, skips blank images, and sorts JLCPCB last",
    () async {
      final offsets = <String>[];
      final images = await loadGalleryImages(
        request: (url, params) async {
          expect(url, "part/");
          expect(params["ordering"], "id");
          offsets.add(params["offset"]!);
          return APIResponse(
            statusCode: 200,
            data: {
              "results": params["offset"] == "0"
                  ? [row(1, "/media/PART-a.png"), row(2, null)]
                  : [
                      row(3, "/media/Z%20photo.jpg"),
                      row(4, "/media/Z%20photo.jpg"),
                      row(5, ""),
                    ],
              "next": params["offset"] == "0" ? "next" : null,
            },
          );
        },
      );
      expect(offsets, ["0", "2"]);
      expect(images.map((image) => image.filename), [
        "Z photo.jpg",
        "PART-a.png",
      ]);
      expect(images.first.parts.map((part) => part.pk), [3, 4]);
      expect(images.first.thumbnail, "/media/Z%20photo.jpg.thumb.png");
      expect(images.last.isJlcpcb, isTrue);
      expect(images.first.matches("IPN-4"), isTrue);
      expect(images.first.matches("description 3"), isTrue);
      expect(images.first.matches("z PHOTO"), isTrue);
      expect(images.first.matches("missing"), isFalse);
    },
  );

  test("rejects denied, malformed and looping pagination responses", () async {
    for (final response in [
      APIResponse(statusCode: 403, data: {"detail": "Forbidden"}),
      APIResponse(statusCode: 200, data: {"other": []}),
      APIResponse(statusCode: 200, data: {"results": [], "next": "next"}),
      APIResponse(
        statusCode: 200,
        data: {
          "results": [row(1, "/image.png")],
          "next": "next",
        },
      ),
      APIResponse(statusCode: 200, data: ["not a part"]),
    ]) {
      await expectLater(
        loadGalleryImages(request: (_, _) async => response),
        throwsStateError,
      );
    }
  });

  test("only attaches media credentials to the selected server origin", () {
    const server = "https://ims.example.com/";
    expect(
      galleryMediaUri("/media/a.jpg", server).toString(),
      "https://ims.example.com/media/a.jpg",
    );
    expect(
      galleryMediaUri("https://ims.example.com/media/a.jpg", server),
      isNotNull,
    );
    for (final source in [
      "https://elsewhere.example/a.jpg",
      "//elsewhere.example/a.jpg",
      "http://ims.example.com/a.jpg",
      "https://ims.example.com:444/a.jpg",
      "https://user@ims.example.com/a.jpg",
      "data:image/png,abc",
      "",
    ]) {
      expect(galleryMediaUri(source, server), isNull);
    }
    expect(galleryMediaUri("/media/a.jpg", "not a server"), isNull);
  });

  testWidgets(
    "toggles supplier images, searches linked parts, and clears search",
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text("1 images"), findsOneWidget);
      expect(find.text("Supplier part"), findsNothing);
      expect(
        Theme.of(
          tester.element(find.text("GPS Module")),
        ).textTheme.bodyMedium!.fontFamily,
        "Public Sans",
      );
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text("2 images"), findsOneWidget);
      final cards = tester.widgetList<Card>(find.byType(Card)).toList();
      expect(cards.length, 2);
      await tester.enterText(find.byType(TextField), "Shared photo");
      await tester.pumpAndSettle();
      expect(find.text("1 images"), findsOneWidget);
      expect(find.text("GPS Module"), findsOneWidget);
      await tester.enterText(find.byType(TextField), "no match");
      await tester.pumpAndSettle();
      expect(find.text("No images found."), findsOneWidget);
      await tester.tap(find.byTooltip("Clear search"));
      await tester.pumpAndSettle();
      expect(find.text("2 images"), findsOneWidget);
    },
  );

  testWidgets(
    "previews original image, copies full filename and opens each linked part",
    (tester) async {
      final opened = <int>[];
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == "Clipboard.setData") {
            copied = (call.arguments as Map)["text"] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(app(openPart: (_, pk) async => opened.add(pk)));
      await tester.pumpAndSettle();
      await tester.tap(find.text("GPS Module"));
      await tester.pumpAndSettle();
      expect(opened, [2]);
      await tester.tap(
        find.byKey(const ValueKey("/media/real-photo.jpg.thumb.png")),
      );
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(
        Theme.of(
          tester.element(find.byType(InteractiveViewer)),
        ).textTheme.bodyMedium!.fontFamily,
        "Public Sans",
      );
      expect(
        find.byKey(const ValueKey("/media/real-photo.jpg")),
        findsOneWidget,
      );
      expect(find.text("Shared photo part"), findsOneWidget);
      await tester.tap(find.byTooltip("Copy filename").last);
      await tester.pumpAndSettle();
      expect(copied, "real-photo.jpg");
      expect(find.text("Filename copied"), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Shared photo part"));
      await tester.pumpAndSettle();
      expect(opened, [2, 3]);
      await tester.tap(find.byTooltip("Close image"));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
    },
  );

  testWidgets("reports load failures, retries, refreshes and keeps filters", (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      app(
        load: () async {
          calls++;
          if (calls == 1) throw StateError("offline");
          return fixture();
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text("Retry"), findsOneWidget);
    await tester.tap(find.text("Retry"));
    await tester.pumpAndSettle();
    expect(find.text("GPS Module"), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.enterText(find.byType(TextField), "supplier");
    await tester.tap(find.byTooltip("Refresh images"));
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(find.text("1 images"), findsOneWidget);
    expect(find.text("Supplier part"), findsOneWidget);
  });

  testWidgets("ignores a load completing after the screen is closed", (
    tester,
  ) async {
    final pending = Completer<List<GalleryImage>>();
    await tester.pumpWidget(app(load: () => pending.future));
    await tester.pumpWidget(const MaterialApp(home: Text("Closed")));
    pending.complete(await fixture());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets("search stays usable with a keyboard and enlarged phone text", (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(() {
      tester.view.resetViewInsets();
      tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(app(textScaler: const TextScaler.linear(2)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), "GPS");
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text("1 images"), findsOneWidget);
  });

  for (final size in [
    const Size(320, 640),
    const Size(800, 1024),
    const Size(640, 360),
  ]) {
    testWidgets("equal responsive cards at $size with enlarged text", (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(textScaler: const TextScaler.linear(2)));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final sizes = find
          .byType(Card)
          .evaluate()
          .map((element) => tester.getSize(find.byWidget(element.widget)))
          .toList();
      expect(sizes, isNotEmpty);
      expect(sizes.toSet().length, 1);
    });
  }
}
