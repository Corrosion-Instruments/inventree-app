import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:inventree/api.dart";
import "package:inventree/barcode/digikey.dart";
import "package:inventree/barcode/supplier_capture.dart";
import "package:inventree/barcode/supplier_inventory.dart";
import "package:inventree/widget/supplier_scan.dart";

const label = "[)>06P478-9919-ND1P069176702201000Q3";

void main() {
  group("Native supplier scanning", () {
    test("decodes DigiKey, LCSC and JLC label fields", () {
      final digiKey = SupplierBarcode.parse(label)!;
      expect(digiKey.supplierName, "DigiKey");
      expect(digiKey.sku, "478-9919-ND");
      expect(digiKey.mpn, "069176702201000");
      expect(digiKey.quantity, "3");

      final lcsc = SupplierBarcode.parse("{pc:C12345,pm:LM358,qty:10}")!;
      expect(lcsc.supplierName, "LCSC / JLC");
      expect(lcsc.sku, "C12345");
      expect(lcsc.mpn, "LM358");
      expect(lcsc.quantity, "10");
      expect(SupplierBarcode.parse("{pc:C12345,pm:,mc:LM358}")!.mpn, "LM358");
      expect(SupplierBarcode.parse("{pm:LM358,qty:10}"), isNull);
    });

    test("captures a label once without contacting the barcode API", () async {
      final received = <String>[];
      final handler = SupplierBarcodeCaptureHandler(received.add);
      await handler.processBarcode(" ");
      await handler.processBarcode(" $label ");
      await handler.processBarcode(label);
      expect(received, [label]);
    });

    test("reads later pages without changing filters", () async {
      final offsets = <String>[];
      final rows = await querySupplierInventory(
        "company/part/",
        {"search": "478-9919-ND"},
        request: (url, params) async {
          expect(url, "company/part/");
          expect(params["search"], "478-9919-ND");
          offsets.add(params["offset"]!);
          final first = params["offset"] == "0";
          return APIResponse(
            statusCode: 200,
            data: {
              "results": [
                {"part": first ? 1 : 2},
              ],
              "next": first ? "next-page" : null,
            },
          );
        },
      );
      expect(offsets, ["0", "1"]);
      expect(rows.map((row) => row["part"]), [1, 2]);
    });

    test("supports unpaginated responses", () async {
      final rows = await querySupplierInventory(
        "part/",
        {},
        request: (url, params) async => APIResponse(
          statusCode: 200,
          data: [
            {"pk": 3},
          ],
        ),
      );
      expect(rows, [
        {"pk": 3},
      ]);
    });

    test(
      "does not turn authentication, server or malformed responses into no-match",
      () async {
        for (final response in [
          APIResponse(statusCode: 403, data: {"detail": "Forbidden"}),
          APIResponse(statusCode: 500),
          APIResponse(statusCode: 200, data: {"detail": "Not a result list"}),
          APIResponse(
            statusCode: 200,
            data: {"results": [], "next": "next-page"},
          ),
        ]) {
          await expectLater(
            querySupplierInventory(
              "part/",
              {},
              request: (url, params) async => response,
            ),
            throwsStateError,
          );
        }
      },
    );
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    SupplierQuery? query,
    Future<String?> Function(BuildContext)? scan,
    Future<void> Function(BuildContext, int)? openPart,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: SupplierScanWidget(
            query: query ?? (url, filters) async => [],
            scan: scan,
            openPart: openPart,
          ),
        ),
      ),
    );
  }

  Future<void> findLabel(WidgetTester tester, [String value = label]) async {
    await tester.enterText(find.byKey(const Key("supplier-barcode")), value);
    await tester.tap(find.text("Find part"));
    await tester.pumpAndSettle();
  }

  testWidgets("pasted label finds and opens the matching inventory part", (
    tester,
  ) async {
    int? opened;
    await pumpScreen(
      tester,
      query: (url, filters) async => [
        {
          "SKU": "478-9919-ND",
          "part": 3092,
          "part_detail": {
            "name": "Insertion tool",
            "description": "Solid state lighting connectors",
          },
        },
      ],
      openPart: (context, pk) async => opened = pk,
    );
    await findLabel(tester);
    expect(find.text("Part found"), findsOneWidget);
    expect(find.text("SKU: 478-9919-ND"), findsOneWidget);
    expect(find.text("MPN: 069176702201000"), findsOneWidget);
    expect(find.text("Label quantity: 3"), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key("supplier-part-3092")));
    await tester.tap(find.byKey(const Key("supplier-part-3092")));
    await tester.pumpAndSettle();
    expect(opened, 3092);
  });

  testWidgets(
    "camera or scanner capture automatically performs native lookup",
    (tester) async {
      final calls = <String>[];
      await pumpScreen(
        tester,
        scan: (context) async => label,
        query: (url, filters) async {
          calls.add(url);
          return [
            {"SKU": "478-9919-ND", "part": 3092},
          ];
        },
      );
      await tester.tap(find.text("Scan label"));
      await tester.pumpAndSettle();
      expect(calls, ["company/part/"]);
      expect(find.text("Part found"), findsOneWidget);
    },
  );

  testWidgets("cancelled scans preserve the previous lookup", (tester) async {
    await pumpScreen(
      tester,
      scan: (context) async => null,
      query: (url, filters) async => [
        {"SKU": "478-9919-ND", "part": 3092},
      ],
    );
    await findLabel(tester);
    await tester.tap(find.text("Scan label"));
    await tester.pumpAndSettle();
    expect(find.text("Part found"), findsOneWidget);
  });

  testWidgets("ambiguous results remain selectable", (tester) async {
    await pumpScreen(
      tester,
      query: (url, filters) async => [
        {"SKU": "478-9919-ND", "part": 1},
        {"SKU": "478-9919-ND", "part": 2},
      ],
    );
    await findLabel(tester);
    expect(find.text("Choose a matching part (2)"), findsOneWidget);
    expect(find.byKey(const Key("supplier-part-1")), findsOneWidget);
    expect(find.byKey(const Key("supplier-part-2")), findsOneWidget);
  });

  testWidgets("empty and unsupported labels never query inventory", (
    tester,
  ) async {
    var calls = 0;
    await pumpScreen(
      tester,
      query: (url, filters) async {
        calls++;
        return [];
      },
    );
    await tester.tap(find.text("Find part"));
    await tester.pumpAndSettle();
    expect(
      find.text("Scan or paste a supplier barcode first."),
      findsOneWidget,
    );
    await findLabel(tester, "INV-123");
    expect(find.textContaining("Unsupported supplier label"), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets("no match is distinct from a connection failure", (tester) async {
    var fail = false;
    await pumpScreen(
      tester,
      query: (url, filters) async {
        if (fail) throw StateError("Offline");
        return [];
      },
    );
    await findLabel(tester);
    expect(find.text("No matching part in inventory"), findsOneWidget);
    fail = true;
    await tester.tap(find.text("Find part"));
    await tester.pumpAndSettle();
    expect(find.textContaining("Could not look up this label"), findsOneWidget);
    expect(find.text("No matching part in inventory"), findsNothing);
  });

  testWidgets("editing or clearing a label removes stale matches", (
    tester,
  ) async {
    await pumpScreen(
      tester,
      query: (url, filters) async => [
        {"SKU": "478-9919-ND", "part": 1},
      ],
    );
    await findLabel(tester);
    await tester.enterText(
      find.byKey(const Key("supplier-barcode")),
      "new label",
    );
    await tester.pumpAndSettle();
    expect(find.text("Part found"), findsNothing);
    await tester.tap(find.text("Clear"));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets("duplicate submissions are blocked while lookup is pending", (
    tester,
  ) async {
    final pending = Completer<List<Map<String, dynamic>>>();
    var calls = 0;
    await pumpScreen(
      tester,
      query: (url, filters) {
        calls++;
        return pending.future;
      },
    );
    await tester.enterText(find.byKey(const Key("supplier-barcode")), label);
    await tester.tap(find.text("Find part"));
    await tester.pump();
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    pending.complete([
      {"SKU": "478-9919-ND", "part": 1},
    ]);
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets("leaving during lookup does not update disposed state", (
    tester,
  ) async {
    final pending = Completer<List<Map<String, dynamic>>>();
    await pumpScreen(tester, query: (url, filters) => pending.future);
    await tester.enterText(find.byKey(const Key("supplier-barcode")), label);
    await tester.tap(find.text("Find part"));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete([
      {"SKU": "478-9919-ND", "part": 1},
    ]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets("small screens and large text have no layout overflow", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpScreen(
      tester,
      textScale: 2,
      query: (url, filters) async => [
        {
          "SKU": "478-9919-ND",
          "part": 3092,
          "part_detail": {
            "name":
                "A very long supplier part name with an inventory description",
          },
        },
      ],
    );
    await tester.enterText(find.byKey(const Key("supplier-barcode")), label);
    await tester.ensureVisible(find.text("Find part"));
    await tester.tap(find.text("Find part"));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text("Part found"), findsOneWidget);
  });
}
