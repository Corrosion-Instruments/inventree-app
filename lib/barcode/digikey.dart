/// Native supplier label decoding and read-only inventory lookup.
///
/// Kept independent of Flutter so camera, intent and keyboard scanners share
/// the same behaviour, without requiring a server barcode plugin.
class SupplierBarcode {
  const SupplierBarcode({
    required this.supplierName,
    required this.sku,
    this.mpn = "",
    this.quantity = "",
  });

  final String supplierName;
  final String sku;
  final String mpn;
  final String quantity;

  static SupplierBarcode? parse(String barcode) {
    final digiKey = DigiKeyBarcode.parse(barcode);
    if (digiKey != null) return digiKey;

    final value = barcode.trim();
    if (!RegExp(r"^\{(?:[^:,]+:[^:,]*,)*[^:,]+:[^:,]*\}$").hasMatch(value)) {
      return null;
    }
    final fields = <String, String>{};
    for (final field in value.substring(1, value.length - 1).split(",")) {
      final separator = field.indexOf(":");
      fields[field.substring(0, separator).trim()] = field
          .substring(separator + 1)
          .trim();
    }
    final sku = fields["pc"] ?? "";
    if (sku.isEmpty) return null;
    final mpn = fields["pm"] ?? "";
    return SupplierBarcode(
      supplierName: "LCSC / JLC",
      sku: sku,
      mpn: mpn.isNotEmpty ? mpn : fields["mc"] ?? "",
      quantity: fields["qty"] ?? "",
    );
  }
}

class DigiKeyBarcode extends SupplierBarcode {
  const DigiKeyBarcode({
    required String sku,
    String mpn = "",
    String quantity = "",
  }) : super(supplierName: "DigiKey", sku: sku, mpn: mpn, quantity: quantity);

  static const _tokens = [
    "30P",
    "11K",
    "14L",
    "11Z",
    "12Z",
    "13Z",
    "20Z",
    "10K",
    "1K",
    "9D",
    "1T",
    "4L",
    "1P",
    "1V",
    "Q",
    "K",
    "P",
  ];

  static DigiKeyBarcode? parse(String barcode) {
    var value = barcode.trim().replaceFirst(RegExp(r"^\][dDQ][0-9]"), "");
    value = value.replaceAll("í", "\x1d");
    if (value.startsWith("[)>06") || value.startsWith(">[)>06")) {
      value = value.replaceAllMapped(
        RegExp("q(?=(?:${_tokens.join('|')}))"),
        (_) => "\x1d",
      );
    }
    final header = RegExp(r"^>?\[\)>\x1e?06\x1d?");
    if (!header.hasMatch(value)) return null;
    value = value
        .replaceFirst(header, "")
        .replaceAll(RegExp(r"[\x1e\x04]+$"), "");

    final fields = <String, String>{};
    for (final segment in value.split("\x1d")) {
      for (final token in _tokens) {
        if (segment.startsWith(token)) {
          fields[token] = segment.substring(token.length).trim();
          break;
        }
      }
    }

    var sku = fields["30P"] ?? fields["P"] ?? "";
    var mpn = fields["1P"] ?? "";
    var quantity = fields["Q"] ?? "";
    if (!value.contains("\x1d")) {
      // Keyboard scanners may omit separators. Only use the best-effort flat
      // decoder in that case; MPNs can legitimately contain field-like text.
      String capture(String token) {
        final start = value.indexOf(token);
        if (start < 0) return "";
        final offset = start + token.length;
        var end = value.length;
        for (final next in _tokens.where(
          (next) => next != token && next != "P",
        )) {
          final index = value.indexOf(next, offset);
          if (index >= 0 && index < end) end = index;
        }
        return value.substring(offset, end).replaceAll("\x1d", "").trim();
      }

      final skuMatch = RegExp(
        "(?:30P|P)([A-Z0-9][A-Z0-9._/-]*?-ND)",
      ).firstMatch(value);
      sku = skuMatch?.group(1) ?? capture(value.contains("30P") ? "30P" : "P");
      mpn = capture("1P");
      quantity = capture("Q");
    }
    if (sku.isEmpty) return null;
    return DigiKeyBarcode(sku: sku, mpn: mpn, quantity: quantity);
  }
}

typedef SupplierQuery =
    Future<List<Map<String, dynamic>>> Function(
      String url,
      Map<String, String> filters,
    );

typedef DigiKeyQuery = SupplierQuery;

class SupplierPartMatch {
  const SupplierPartMatch(this.pk, this.label, this.description);

  final int pk;
  final String label;
  final String description;
}

typedef DigiKeyPartMatch = SupplierPartMatch;

class SupplierPartLookup {
  SupplierPartLookup(this.query);

  final SupplierQuery query;

  Future<List<SupplierPartMatch>> find(SupplierBarcode barcode) async {
    bool exact(dynamic value, String expected) =>
        value is String && value.toLowerCase() == expected.toLowerCase();

    List<SupplierPartMatch> matches(
      List<Map<String, dynamic>> rows, {
      bool direct = false,
    }) {
      final parts = <int, SupplierPartMatch>{};
      for (final row in rows) {
        final pk = direct ? row["pk"] : row["part"];
        if (pk is! int || pk <= 0) continue;
        final detail = direct ? row : row["part_detail"];
        final data = detail is Map ? detail : <String, dynamic>{};
        final name = data["full_name"] ?? data["name"] ?? "Part #$pk";
        final ipn = data["IPN"] ?? "";
        parts[pk] = SupplierPartMatch(
          pk,
          "$name${ipn == '' ? '' : ' ($ipn)'}",
          "${data['description'] ?? ''}",
        );
      }
      return parts.values.toList();
    }

    final supplierRows = await query("company/part/", {
      // The server's exact SKU/MPN filters can be case-sensitive. Search
      // narrows the results; comparisons below enforce case-insensitive equality.
      "search": barcode.sku,
      "part_detail": "true",
    });
    var found = matches(
      supplierRows.where((row) => exact(row["SKU"], barcode.sku)).toList(),
    );
    if (found.isNotEmpty || barcode.mpn.isEmpty) return found;

    final manufacturerRows = await query("company/part/manufacturer/", {
      "search": barcode.mpn,
      "part_detail": "true",
    });
    found = matches(
      manufacturerRows.where((row) => exact(row["MPN"], barcode.mpn)).toList(),
    );
    if (found.isNotEmpty) return found;

    final parts = await query("part/", {"search": barcode.mpn});
    return matches(
      parts
          .where(
            (row) =>
                exact(row["name"], barcode.mpn) ||
                exact(row["IPN"], barcode.mpn),
          )
          .toList(),
      direct: true,
    );
  }
}

class DigiKeyPartLookup extends SupplierPartLookup {
  DigiKeyPartLookup(DigiKeyQuery query) : super(query);
}
