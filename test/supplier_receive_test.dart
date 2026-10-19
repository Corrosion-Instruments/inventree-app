import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:inventree/api.dart";
import "package:inventree/barcode/supplier_receiving.dart";
import "package:inventree/user_profile.dart";
import "package:inventree/widget/supplier_receive.dart";

import "setup.dart" show CustomBinding;

const rawLabel = "[)>06P478-9919-ND1P069176702201000Q3";
const csrf = "abcdefghijklmnopqrstuvwxyz012345";

Map<String, dynamic> previewData({
  bool existing = true,
  bool duplicate = false,
}) => {
  "parsed": {
    "supplier_name": "DigiKey",
    "sku": "478-9919-ND",
    "mpn": "069176702201000",
    "quantity": "3",
  },
  "source": {
    "name": "Insertion tool",
    "mpn": "069176702201000",
    "lookup_status": "barcode",
    "image_url": "https://example.com/image.png",
    "parameters": {"Type": "Insertion tool"},
  },
  "part": existing ? {"pk": 3092, "label": "Insertion tool"} : null,
  "supplier_part": existing ? {"pk": 10, "label": "DigiKey 478-9919-ND"} : null,
  "part_candidates": [
    {"pk": 3093, "label": "Another insertion tool"},
  ],
  "category_suggestion": {"pk": 6, "path": "Tools", "confidence": "exact"},
  "default_location": {
    "pk": 4,
    "label": "Incoming",
    "path": "Stores / Incoming",
  },
  "duplicate_stock_item": duplicate
      ? {"pk": 77, "label": "Previously received stock"}
      : null,
  "auto_receive": true,
};

Map<String, dynamic> receiptData() => {
  "success": true,
  "quantity": "3",
  "part": {"pk": 3092, "label": "Insertion tool"},
  "stock_item": {"pk": 81, "label": "Insertion tool (3 in Incoming)"},
  "metadata_sync": {"errors": []},
};

class Fixture {
  Fixture({
    this.existing = true,
    this.duplicate = false,
    this.suggestCategory = true,
  });
  bool existing;
  bool duplicate;
  bool suggestCategory;
  int posts = 0;
  final calls = <String>[];
  Map<String, dynamic>? received;
  Future<SupplierReceivingResponse> Function()? onReceive;
  late final client = SupplierReceivingClient((
    method,
    path,
    headers,
    body,
  ) async {
    calls.add("$method $path");
    if (method == "POST") {
      expect(headers["X-CSRFToken"], csrf);
      expect(headers["Cookie"], "csrftoken=$csrf");
    }
    if (path == supplierScanPath) {
      return const SupplierReceivingResponse(200, csrfCookie: csrf);
    }
    if (path.endsWith("preview/")) {
      return SupplierReceivingResponse(
        200,
        data: {
          ...previewData(existing: existing, duplicate: duplicate),
          if (!suggestCategory) "category_suggestion": null,
        },
      );
    }
    if (path.endsWith("categories/")) {
      return const SupplierReceivingResponse(
        200,
        data: {
          "categories": [
            {"pk": 1, "path": "Root", "structural": true},
            {"pk": 6, "path": "Tools", "structural": false},
          ],
        },
      );
    }
    if (path.endsWith("locations/")) {
      return const SupplierReceivingResponse(
        200,
        data: {
          "locations": [
            {"pk": 1, "path": "Stores", "structural": true},
            {"pk": 4, "path": "Stores / Incoming", "structural": false},
            {"pk": 5, "path": "Stores / Shelf A", "structural": false},
          ],
        },
      );
    }
    if (path.contains("parts/?")) {
      return const SupplierReceivingResponse(
        200,
        data: {
          "parts": [
            {"pk": 3094, "label": "Manually selected tool"},
          ],
        },
      );
    }
    if (path.endsWith("receive/")) {
      posts++;
      received = body;
      return onReceive != null
          ? await onReceive!()
          : SupplierReceivingResponse(200, data: receiptData());
    }
    throw StateError("Unexpected request: $method $path");
  });
}

void main() {
  CustomBinding();
  group("Supplier receiving client", () {
    test(
      "previews through CSRF handshake, filters structural choices, never auto receives",
      () async {
        final fixture = Fixture();
        final preview = await fixture.client.preview(rawLabel);
        expect(preview.part!.pk, 3092);
        expect(preview.categories.map((choice) => choice.pk), [6]);
        expect(preview.locations.map((choice) => choice.pk), [4, 5]);
        expect(preview.suggestedCategory!.pk, 6);
        expect(fixture.posts, 0);
        expect(
          fixture.calls.where((path) => path == "GET $supplierScanPath"),
          hasLength(1),
        );
      },
    );

    test(
      "sends reviewed quantity, part, location and explicit duplicate/image choices",
      () async {
        final fixture = Fixture();
        await fixture.client.preview(rawLabel);
        await fixture.client.receive(
          barcode: rawLabel,
          quantity: "2.5",
          partId: 3092,
          categoryId: 6,
          locationId: 5,
          allowDuplicate: true,
          useSupplierImage: false,
        );
        expect(fixture.received, {
          "barcode": rawLabel,
          "quantity": "2.5",
          "part_id": 3092,
          "category_id": null,
          "location_id": 5,
          "allow_duplicate": true,
          "use_supplier_image": false,
        });
        expect(
          fixture.calls.where((path) => path == "GET $supplierScanPath"),
          hasLength(1),
        );
      },
    );

    test("new parts require a category or an existing part", () async {
      final fixture = Fixture(existing: false);
      await expectLater(
        fixture.client.receive(barcode: rawLabel, quantity: "3"),
        throwsA(isA<SupplierReceivingException>()),
      );
      expect(fixture.posts, 0);
      await fixture.client.receive(
        barcode: rawLabel,
        quantity: "3",
        categoryId: 6,
      );
      expect(fixture.received!["category_id"], 6);
      expect(fixture.received!["part_id"], isNull);
    });

    test(
      "rejects zero, negatives and non-finite quantities before any stock request",
      () async {
        final fixture = Fixture();
        for (final quantity in [
          "",
          "0",
          "0.00",
          "-3",
          "NaN",
          "Infinity",
          "1e5",
          "abc",
          "9" * 400,
        ]) {
          await expectLater(
            fixture.client.receive(
              barcode: rawLabel,
              quantity: quantity,
              partId: 3092,
            ),
            throwsA(isA<SupplierReceivingException>()),
          );
        }
        expect(fixture.calls, isEmpty);
        expect(validSupplierReceiveQuantity(".5"), isTrue);
      },
    );

    test(
      "preserves duplicate conflicts and server permission errors",
      () async {
        final fixture = Fixture();
        fixture.onReceive = () async => const SupplierReceivingResponse(
          409,
          data: {
            "error": "Already received",
            "duplicate_stock_item": {"pk": 77, "label": "Existing stock"},
          },
        );
        await expectLater(
          fixture.client.receive(
            barcode: rawLabel,
            quantity: "3",
            partId: 3092,
          ),
          throwsA(
            isA<SupplierReceivingException>()
                .having((e) => e.duplicate?.pk, "duplicate", 77)
                .having((e) => e.receiptUncertain, "uncertain", false),
          ),
        );
        fixture.onReceive = () async => const SupplierReceivingResponse(
          403,
          data: {"error": "Missing stock add permission"},
        );
        await expectLater(
          fixture.client.receive(
            barcode: rawLabel,
            quantity: "3",
            partId: 3092,
          ),
          throwsA(
            isA<SupplierReceivingException>().having(
              (e) => e.message,
              "permission",
              "Missing stock add permission",
            ),
          ),
        );
      },
    );

    test(
      "unavailable plugin, authentication and missing CSRF cookie stop before POST",
      () async {
        for (final status in [401, 403, 404, 200]) {
          final methods = <String>[];
          final client = SupplierReceivingClient((
            method,
            path,
            headers,
            body,
          ) async {
            methods.add(method);
            return SupplierReceivingResponse(status);
          });
          await expectLater(
            client.preview(rawLabel),
            throwsA(isA<SupplierReceivingException>()),
          );
          expect(methods, ["GET"]);
        }
      },
    );

    test(
      "ambiguous network/server/malformed success failures are not retried",
      () async {
        for (final response in [
          null,
          const SupplierReceivingResponse(500),
          const SupplierReceivingResponse(200, data: {}),
          const SupplierReceivingResponse(200, data: "login page"),
        ]) {
          final fixture = Fixture();
          fixture.onReceive = () async {
            if (response == null) throw const SocketException("Response lost");
            return response;
          };
          await expectLater(
            fixture.client.receive(
              barcode: rawLabel,
              quantity: "3",
              partId: 3092,
            ),
            throwsA(
              isA<SupplierReceivingException>().having(
                (e) => e.receiptUncertain,
                "uncertain",
                true,
              ),
            ),
          );
          expect(fixture.posts, 1);
        }
      },
    );

    test(
      "real HTTP transport sends profile token, CSRF cookie and same-origin Referer",
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final api = InvenTreeAPI();
        final oldProfile = api.profile;
        final origin = "http://127.0.0.1:${server.port}";
        api.profile = UserProfile(server: origin, token: "test-only-token");
        final requests = <String>[];
        final serverErrors = <Object>[];
        var redirect = false;
        final subscription = server.listen((req) async {
          try {
            requests.add("${req.method} ${req.uri.path}");
            expect(req.headers.value("authorization"), "Token test-only-token");
            expect(req.headers.value("referer"), "$origin$supplierScanPath");
            if (req.method == "POST") {
              expect(req.contentLength, greaterThan(0));
              expect(req.headers.value("x-csrftoken"), csrf);
              expect(
                req.cookies.singleWhere((c) => c.name == "csrftoken").value,
                csrf,
              );
              final body =
                  jsonDecode(await utf8.decoder.bind(req).join()) as Map;
              expect(body["barcode"], rawLabel);
            }
            if (req.uri.path == supplierScanPath) {
              if (redirect) {
                req.response.statusCode = 302;
                req.response.headers.set("location", "$origin/do-not-follow/");
              } else {
                req.response.cookies.add(Cookie("csrftoken", csrf));
                req.response.write("<html>Supplier Scan</html>");
              }
            } else {
              req.response.headers.contentType = ContentType.json;
              req.response.write(jsonEncode(receiptData()));
            }
          } catch (error) {
            serverErrors.add(error);
          } finally {
            await req.response.close();
          }
        });
        try {
          final client = SupplierReceivingClient.inventory();
          final result = await client.receive(
            barcode: rawLabel,
            quantity: "3",
            partId: 3092,
          );
          expect(result["stock_item"]["pk"], 81);
          expect(requests, [
            "GET $supplierScanPath",
            "POST ${supplierScanPath}receive/",
          ]);
          expect(serverErrors, isEmpty);
          redirect = true;
          await expectLater(
            SupplierReceivingClient.inventory().receive(
              barcode: rawLabel,
              quantity: "3",
              partId: 3092,
            ),
            throwsA(
              isA<SupplierReceivingException>().having(
                (e) => e.status,
                "redirect",
                302,
              ),
            ),
          );
          expect(requests, [
            "GET $supplierScanPath",
            "POST ${supplierScanPath}receive/",
            "GET $supplierScanPath",
          ]);
          api.profile = UserProfile(server: origin, token: "other-test-token");
          await expectLater(
            client.receive(barcode: rawLabel, quantity: "3", partId: 3092),
            throwsA(
              isA<SupplierReceivingException>().having(
                (e) => e.message,
                "account changed",
                contains("account changed"),
              ),
            ),
          );
          expect(requests, hasLength(3));
        } finally {
          api.profile = oldProfile;
          await subscription.cancel();
          await server.close(force: true);
        }
      },
    );
  });

  Future<void> pumpReceiving(
    WidgetTester tester,
    Fixture fixture, {
    bool permission = true,
    Future<void> Function(BuildContext, int)? openStock,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: SupplierReceiveWidget(
            barcode: rawLabel,
            canReceive: permission,
            client: fixture.client,
            openStock: openStock,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapReceive(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key("receive-stock")));
    await tester.tap(find.byKey(const Key("receive-stock")));
    await tester.pumpAndSettle();
  }

  testWidgets(
    "preview never receives automatically; one explicit tap receives and opens stock",
    (tester) async {
      final fixture = Fixture();
      int? opened;
      await pumpReceiving(
        tester,
        fixture,
        openStock: (_, pk) async => opened = pk,
      );
      expect(fixture.posts, 0);
      expect(find.text("SKU: 478-9919-ND"), findsOneWidget);
      await tester.enterText(find.byKey(const Key("receive-quantity")), "2.5");
      await tester.ensureVisible(
        find.byKey(const ValueKey("receive-location-4")),
      );
      await tester.tap(find.byKey(const ValueKey("receive-location-4")));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Stores / Shelf A").last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text("Import supplier photo"));
      await tester.tap(find.text("Import supplier photo"));
      await tester.pumpAndSettle();
      await tapReceive(tester);
      expect(fixture.posts, 1);
      expect(fixture.received!["quantity"], "2.5");
      expect(fixture.received!["part_id"], 3092);
      expect(fixture.received!["location_id"], 5);
      expect(fixture.received!["use_supplier_image"], false);
      expect(fixture.received!["allow_duplicate"], false);
      expect(find.text("Stock received"), findsOneWidget);
      expect(find.byKey(const Key("receive-stock")), findsNothing);
      await tester.tap(find.text("View received stock"));
      await tester.pumpAndSettle();
      expect(opened, 81);
    },
  );

  testWidgets(
    "duplicate warning blocks receive until additional stock is explicitly chosen",
    (tester) async {
      final fixture = Fixture(duplicate: true);
      await pumpReceiving(tester, fixture);
      expect(find.text("This label has already been received"), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key("receive-stock")))
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text("Receive this label again"));
      await tester.tap(find.text("Receive this label again"));
      await tester.pumpAndSettle();
      await tapReceive(tester);
      expect(fixture.received!["allow_duplicate"], true);
    },
  );

  testWidgets(
    "new part uses suggested category, existing search result uses selected part",
    (tester) async {
      final fixture = Fixture(existing: false);
      await pumpReceiving(tester, fixture);
      await tester.enterText(
        find.byKey(const Key("receive-part-search")),
        "Tool",
      );
      await tester.ensureVisible(find.byTooltip("Search parts"));
      await tester.tap(find.byTooltip("Search parts"));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey("receive-part-null")),
      );
      await tester.tap(find.byKey(const ValueKey("receive-part-null")));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Manually selected tool").last);
      await tester.pumpAndSettle();
      await tapReceive(tester);
      expect(fixture.received!["part_id"], 3094);
      expect(fixture.received!["category_id"], isNull);
    },
  );

  testWidgets("new part needs a category when there is no suggestion", (
    tester,
  ) async {
    final fixture = Fixture(existing: false, suggestCategory: false);
    await pumpReceiving(tester, fixture);
    await tapReceive(tester);
    expect(find.text("Select a category or an existing part."), findsOneWidget);
    expect(fixture.posts, 0);
    await tester.ensureVisible(
      find.byKey(const ValueKey("receive-category-null")),
    );
    await tester.tap(find.byKey(const ValueKey("receive-category-null")));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Tools").last);
    await tester.pumpAndSettle();
    await tapReceive(tester);
    expect(fixture.received!["category_id"], 6);
  });

  testWidgets("new part can be created in the suggested category", (
    tester,
  ) async {
    final fixture = Fixture(existing: false);
    await pumpReceiving(tester, fixture);
    await tapReceive(tester);
    expect(fixture.received!["part_id"], isNull);
    expect(fixture.received!["category_id"], 6);
  });

  testWidgets("invalid quantity and missing permissions cannot submit stock", (
    tester,
  ) async {
    final fixture = Fixture();
    await pumpReceiving(tester, fixture);
    await tester.enterText(find.byKey(const Key("receive-quantity")), "0");
    await tapReceive(tester);
    expect(find.text("Enter a quantity greater than zero."), findsOneWidget);
    expect(fixture.posts, 0);
    await tester.pumpWidget(const SizedBox());
    await pumpReceiving(tester, fixture, permission: false);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key("receive-stock")))
          .onPressed,
      isNull,
    );
    expect(
      find.text("You need stock add permission to receive stock."),
      findsOneWidget,
    );
  });

  testWidgets(
    "server duplicate discovered at submit locks the next submission",
    (tester) async {
      final fixture = Fixture();
      fixture.onReceive = () async => const SupplierReceivingResponse(
        409,
        data: {
          "error": "Already received",
          "duplicate_stock_item": {"pk": 77, "label": "Existing stock"},
        },
      );
      await pumpReceiving(tester, fixture);
      await tapReceive(tester);
      expect(fixture.posts, 1);
      expect(find.text("This label has already been received"), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key("receive-stock")))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    "unconfirmed receipt requires a refreshed preview before another POST",
    (tester) async {
      final fixture = Fixture();
      fixture.onReceive = () async =>
          throw const SocketException("Response lost");
      await pumpReceiving(tester, fixture);
      await tapReceive(tester);
      expect(fixture.posts, 1);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key("receive-stock")))
            .onPressed,
        isNull,
      );
      fixture.duplicate = true;
      await tester.ensureVisible(find.text("Refresh preview"));
      await tester.tap(find.text("Refresh preview"));
      await tester.pumpAndSettle();
      expect(find.text("This label has already been received"), findsOneWidget);
      expect(fixture.posts, 1);
    },
  );

  testWidgets("busy receipt cannot submit twice and safely survives disposal", (
    tester,
  ) async {
    final fixture = Fixture();
    final pending = Completer<SupplierReceivingResponse>();
    fixture.onReceive = () => pending.future;
    await pumpReceiving(tester, fixture);
    await tester.ensureVisible(find.byKey(const Key("receive-stock")));
    await tester.tap(find.byKey(const Key("receive-stock")));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key("receive-stock")))
          .onPressed,
      isNull,
    );
    expect(fixture.posts, 1);
    await tester.pumpWidget(const SizedBox());
    pending.complete(SupplierReceivingResponse(200, data: receiptData()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets("small screen, long choices and large text have no overflow", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpReceiving(
      tester,
      Fixture(existing: false, duplicate: true),
      textScale: 2,
    );
    await tester.ensureVisible(find.byKey(const Key("receive-quantity")));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
