import "package:flutter_test/flutter_test.dart";
import "package:inventree/barcode/barcode.dart";
import "package:inventree/barcode/digikey.dart";

void main() {
  const standard = "[)>\x1e06\x1dP296-6501-1-ND\x1d1PSN74HC00N\x1dQ25\x1e\x04";

  group("DigiKey decoding", () {
    test("camera data, AIM prefixes and keyboard separator substitutions", () {
      for (final barcode in [
        standard,
        "]d2$standard",
        "]Q3$standard",
        "[)>06qP296-6501-1-NDq1PSN74HC00NqQ25",
        ">[)>06íP296-6501-1-NDí1PSN74HC00NíQ25",
        "[)>06P296-6501-1-ND1PSN74HC00NQ25",
      ]) {
        final parsed = DigiKeyBarcode.parse(barcode);
        expect(parsed, isNotNull, reason: barcode);
        expect(parsed!.sku, "296-6501-1-ND", reason: barcode);
        expect(parsed.mpn, "SN74HC00N", reason: barcode);
        expect(parsed.quantity, "25", reason: barcode);
      }
    });

    test("30P identifier and MPN containing Q without quantity", () {
      final parsed = DigiKeyBarcode.parse(
        "[)>\x1e06\x1d30P123-ND\x1d1PABCQ123\x1e\x04",
      );
      expect(parsed!.sku, "123-ND");
      expect(parsed.mpn, "ABCQ123");
      expect(parsed.quantity, isEmpty);
    });

    test(
      "preserves field-like text inside a separated manufacturer number",
      () {
        final parsed = DigiKeyBarcode.parse(
          "[)>\x1e06\x1dP123-ND\x1d1PABC30P10KQ123\x1dQ7\x1e\x04",
        );
        expect(parsed!.sku, "123-ND");
        expect(parsed.mpn, "ABC30P10KQ123");
        expect(parsed.quantity, "7");
      },
    );

    test("ignores internal QR codes, supplier URLs and incomplete labels", () {
      for (final value in [
        "",
        '{"part": 1}',
        "INV-123",
        "https://digikey.com/123",
        "[)>06Q25",
        "[)>06",
      ]) {
        expect(DigiKeyBarcode.parse(value), isNull, reason: value);
      }
    });
  });

  group("DigiKey inventory lookup", () {
    const barcode = DigiKeyBarcode(sku: "296-6501-1-ND", mpn: "SN74HC00N");
    test("prefers exact SKU and deduplicates inventory parts", () async {
      final calls = <String>[];
      final lookup = DigiKeyPartLookup((url, filters) async {
        calls.add(url);
        expect(filters["search"], barcode.sku);
        return [
          {
            "SKU": barcode.sku.toLowerCase(),
            "part": 7,
            "part_detail": {"name": "Logic", "IPN": "IC007"},
          },
          {
            "SKU": barcode.sku,
            "part": 7,
            "part_detail": {"name": "Logic", "IPN": "IC007"},
          },
          {"SKU": "${barcode.sku}-OTHER", "part": 8},
        ];
      });
      final matches = await lookup.find(barcode);
      expect(matches.map((part) => part.pk), [7]);
      expect(matches.single.label, "Logic (IC007)");
      expect(calls, ["company/part/"]);
    });

    test("keeps ambiguous exact matches for user selection", () async {
      final lookup = DigiKeyPartLookup(
        (url, filters) async => [
          {"SKU": barcode.sku, "part": 7},
          {"SKU": barcode.sku, "part": 8},
        ],
      );
      expect((await lookup.find(barcode)).map((part) => part.pk), [7, 8]);
    });

    test("falls back to exact MPN, rejecting fuzzy results", () async {
      final lookup = DigiKeyPartLookup((url, filters) async {
        if (url == "company/part/") return [];
        expect(url, "company/part/manufacturer/");
        expect(filters["search"], barcode.mpn);
        return [
          {"MPN": barcode.mpn.toLowerCase(), "part": 9},
          {"MPN": "${barcode.mpn}D", "part": 10},
        ];
      });
      expect((await lookup.find(barcode)).single.pk, 9);
    });

    test("falls back to exact name or IPN only", () async {
      final lookup = DigiKeyPartLookup((url, filters) async {
        if (url != "part/") return [];
        return [
          {"pk": 11, "name": barcode.mpn},
          {"pk": 12, "IPN": barcode.mpn},
          {"pk": 13, "name": "${barcode.mpn}D"},
          {"pk": 14, "description": barcode.mpn},
        ];
      });
      expect((await lookup.find(barcode)).map((part) => part.pk), [11, 12]);
    });

    test("returns no match and avoids searching with a missing MPN", () async {
      final calls = <String>[];
      final lookup = DigiKeyPartLookup((url, filters) async {
        calls.add(url);
        return [];
      });
      expect(
        await lookup.find(const DigiKeyBarcode(sku: "MISSING-ND")),
        isEmpty,
      );
      expect(calls, ["company/part/"]);
    });

    test(
      "query failures propagate instead of reporting a false no-match",
      () async {
        final lookup = DigiKeyPartLookup(
          (url, filters) async => throw StateError("Offline"),
        );
        await expectLater(lookup.find(barcode), throwsStateError);
      },
    );
  });

  test(
    "general scanner resolves DigiKey natively and opens the inventory part",
    () async {
      final calls = <String>[];
      final handler = _CapturingBarcodeHandler((url, filters) async {
        calls.add(url);
        return [
          {"SKU": "296-6501-1-ND", "part": 42},
        ];
      });
      await handler.processBarcode(standard);
      expect(calls, ["company/part/"]);
      expect(handler.match, {
        "part": {"pk": 42},
      });
    },
  );
}

class _CapturingBarcodeHandler extends BarcodeScanHandler {
  _CapturingBarcodeHandler(DigiKeyQuery query) : super(digiKeyQuery: query);

  Map<String, dynamic>? match;

  @override
  Future<void> onBarcodeMatched(Map<String, dynamic> data) async {
    match = data;
  }
}
