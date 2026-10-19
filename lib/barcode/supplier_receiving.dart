import "dart:async";
import "dart:convert";
import "dart:io";

import "package:inventree/api.dart";

const supplierScanPath = "/plugin/supplier-scan/";

class SupplierReceivingResponse {
  const SupplierReceivingResponse(this.status, {this.data, this.csrfCookie});
  final int status;
  final dynamic data;
  final String? csrfCookie;
}

typedef SupplierReceivingRequest =
    Future<SupplierReceivingResponse> Function(
      String method,
      String path,
      Map<String, String> headers,
      Map<String, dynamic>? body,
    );

class SupplierReceivingException implements Exception {
  const SupplierReceivingException(
    this.message, {
    this.status,
    this.duplicate,
    this.receiptUncertain = false,
  });
  final String message;
  final int? status;
  final SupplierReceivingChoice? duplicate;
  final bool receiptUncertain;

  @override
  String toString() => message;
}

class SupplierReceivingChoice {
  const SupplierReceivingChoice(this.pk, this.label);
  factory SupplierReceivingChoice.fromJson(Map<String, dynamic> data) {
    final pk = data["pk"];
    if (pk is! int || pk <= 0) throw const FormatException("Invalid selection");
    return SupplierReceivingChoice(
      pk,
      "${data['path'] ?? data['label'] ?? data['name'] ?? '#$pk'}",
    );
  }
  final int pk;
  final String label;
}

Map<String, dynamic> _map(dynamic value) =>
    Map<String, dynamic>.from(value as Map);

SupplierReceivingChoice? _choice(dynamic value) =>
    value == null ? null : SupplierReceivingChoice.fromJson(_map(value));

List<SupplierReceivingChoice> _choices(
  dynamic value, {
  bool excludeStructural = false,
}) {
  return (value as List)
      .map(_map)
      .where((row) => !excludeStructural || row["structural"] != true)
      .map(SupplierReceivingChoice.fromJson)
      .toList();
}

class SupplierReceivingPreview {
  SupplierReceivingPreview.fromJson(
    Map<String, dynamic> data, {
    required this.categories,
    required this.locations,
  }) : parsed = _map(data["parsed"]),
       source = _map(data["source"]),
       part = _choice(data["part"]),
       supplierPart = _choice(data["supplier_part"]),
       duplicate = _choice(data["duplicate_stock_item"]),
       defaultLocation = _choice(data["default_location"]),
       suggestedCategory = _choice(
         data["category_suggestion"]?["pk"] == null
             ? null
             : data["category_suggestion"],
       ),
       candidates = _choices(data["part_candidates"] ?? []) {
    if (parsed["sku"] is! String || (parsed["sku"] as String).isEmpty) {
      throw const FormatException("Invalid receiving preview");
    }
  }
  final Map<String, dynamic> parsed;
  final Map<String, dynamic> source;
  final SupplierReceivingChoice? part;
  final SupplierReceivingChoice? supplierPart;
  final SupplierReceivingChoice? duplicate;
  final SupplierReceivingChoice? defaultLocation;
  final SupplierReceivingChoice? suggestedCategory;
  final List<SupplierReceivingChoice> candidates;
  final List<SupplierReceivingChoice> categories;
  final List<SupplierReceivingChoice> locations;
}

bool validSupplierReceiveQuantity(String value) {
  final text = value.trim();
  final number = double.tryParse(text);
  return RegExp(r"^(?:\d+(?:\.\d*)?|\.\d+)$").hasMatch(text) &&
      number != null &&
      number.isFinite &&
      number > 0;
}

/// Native client for the installed Supplier Scan service. Supplier API secrets,
/// part import, barcode assignment and duplicate checks stay on the server.
class SupplierReceivingClient {
  SupplierReceivingClient(this.request);

  factory SupplierReceivingClient.inventory() {
    final api = InvenTreeAPI();
    final profile = api.profile;
    final server = api.baseUrl;
    final token = api.token;
    return SupplierReceivingClient((method, path, headers, body) async {
      // Never reuse a CSRF cookie or a receiving preview on another account.
      void checkProfile() {
        if (api.profile != profile ||
            api.baseUrl != server ||
            api.token != token) {
          throw const SupplierReceivingException(
            "Your server or account changed. Reopen Supplier Scan.",
          );
        }
      }

      checkProfile();
      final req = await api.apiRequest(path, method, headers: headers);
      if (req == null) throw const SocketException("No receiving connection");
      checkProfile();
      req.followRedirects = false;
      req.headers.set(
        HttpHeaders.refererHeader,
        "${req.uri.origin}$supplierScanPath",
      );
      if (body != null) {
        final encoded = utf8.encode(jsonEncode(body));
        req.contentLength = encoded.length;
        req.add(encoded);
      }
      // Supplier metadata and image imports can take longer than a stock GET.
      final res = await req.close().timeout(const Duration(seconds: 120));
      final csrf = res.cookies
          .where((cookie) => cookie.name == "csrftoken")
          .firstOrNull
          ?.value;
      final text = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 120));
      checkProfile();
      dynamic data;
      if (path != supplierScanPath) {
        try {
          data = jsonDecode(text);
        } on FormatException {
          /* Handled below. */
        }
      }
      return SupplierReceivingResponse(
        res.statusCode,
        data: data,
        csrfCookie: csrf,
      );
    });
  }

  final SupplierReceivingRequest request;
  String? _csrf;

  Future<void> _prepare() async {
    if (_csrf != null) return;
    final res = await request("GET", supplierScanPath, {}, null);
    _check(res);
    if (!RegExp(
      r"^(?:[A-Za-z0-9]{32}|[A-Za-z0-9]{64})$",
    ).hasMatch(res.csrfCookie ?? "")) {
      throw const SupplierReceivingException(
        "Could not prepare receiving. Check that Supplier Scan is enabled on this server.",
      );
    }
    _csrf = res.csrfCookie;
  }

  void _check(SupplierReceivingResponse res, {bool receiving = false}) {
    if (res.status >= 200 && res.status < 300) return;
    final body = res.data is Map ? _map(res.data) : <String, dynamic>{};
    final message = switch (res.status) {
      401 => "Sign in again before receiving stock.",
      404 =>
        "Supplier Scan receiving is unavailable. Enable the Supplier Scan plugin on this server.",
      403 =>
        body["error"]?.toString() ??
            "You do not have permission to receive stock, or the receiving session expired. Reopen this screen.",
      _ =>
        body["error"]?.toString() ??
            "The server could not complete this request (${res.status}).",
    };
    throw SupplierReceivingException(
      message,
      status: res.status,
      duplicate: _choice(body["duplicate_stock_item"]),
      receiptUncertain: receiving && (res.status >= 500 || res.status < 200),
    );
  }

  Future<Map<String, dynamic>> _json(
    String endpoint, {
    String method = "GET",
    Map<String, dynamic>? body,
  }) async {
    final receiving = endpoint == "receive/";
    try {
      if (method == "POST") await _prepare();
    } on SupplierReceivingException {
      rethrow;
    } catch (_) {
      throw const SupplierReceivingException(
        "Could not connect to Supplier Scan. Check your connection and try again.",
      );
    }
    try {
      final res = await request(method, "$supplierScanPath$endpoint", {
        if (method == "POST") ...{
          "X-CSRFToken": _csrf!,
          "Cookie": "csrftoken=$_csrf",
        },
      }, body);
      _check(res, receiving: receiving);
      if (res.data is! Map) {
        throw const FormatException("Invalid receiving response");
      }
      return _map(res.data);
    } on SupplierReceivingException {
      rethrow;
    } catch (_) {
      throw SupplierReceivingException(
        receiving
            ? "The receipt could not be confirmed. Refresh the preview and check the stock before trying again."
            : "Could not load receiving details. Check your connection and try again.",
        receiptUncertain: receiving,
      );
    }
  }

  Future<SupplierReceivingPreview> preview(String barcode) async {
    final data = await _json(
      "preview/",
      method: "POST",
      body: {"barcode": barcode.trim()},
    );
    final options = await Future.wait([
      _json("categories/"),
      _json("locations/"),
    ]);
    try {
      return SupplierReceivingPreview.fromJson(
        data,
        categories: _choices(options[0]["categories"], excludeStructural: true),
        locations: _choices(options[1]["locations"], excludeStructural: true),
      );
    } catch (_) {
      throw const SupplierReceivingException(
        "The server returned an invalid receiving preview.",
      );
    }
  }

  Future<List<SupplierReceivingChoice>> searchParts(String search) async {
    final query = Uri(queryParameters: {"q": search.trim()}).query;
    final data = await _json("parts/?$query");
    return _choices(data["parts"]);
  }

  Future<Map<String, dynamic>> receive({
    required String barcode,
    required String quantity,
    int? partId,
    int? categoryId,
    int? locationId,
    bool allowDuplicate = false,
    bool useSupplierImage = true,
  }) async {
    if (!validSupplierReceiveQuantity(quantity)) {
      throw const SupplierReceivingException(
        "Enter a quantity greater than zero.",
      );
    }
    if (partId == null && categoryId == null) {
      throw const SupplierReceivingException(
        "Select an existing part or a category for a new part.",
      );
    }
    final data = await _json(
      "receive/",
      method: "POST",
      body: {
        "barcode": barcode.trim(),
        "quantity": quantity.trim(),
        "part_id": partId,
        "category_id": partId == null ? categoryId : null,
        "location_id": locationId,
        "allow_duplicate": allowDuplicate,
        "use_supplier_image": useSupplierImage,
      },
    );
    if (data["success"] != true ||
        data["stock_item"] is! Map ||
        data["stock_item"]["pk"] is! int ||
        (data["stock_item"]["pk"] as int) <= 0) {
      throw const SupplierReceivingException(
        "The receipt could not be confirmed. Refresh the preview and check stock before trying again.",
        receiptUncertain: true,
      );
    }
    return data;
  }
}
