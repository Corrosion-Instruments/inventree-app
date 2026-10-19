import "package:inventree/api.dart";

typedef SupplierInventoryRequest =
    Future<APIResponse> Function(String url, Map<String, String> params);

/// Query every inventory result page using the current server profile.
/// All supplier lookups use GET requests to the normal inventory API.
Future<List<Map<String, dynamic>>> querySupplierInventory(
  String url,
  Map<String, String> filters, {
  SupplierInventoryRequest? request,
}) async {
  final rows = <Map<String, dynamic>>[];
  var offset = 0;
  while (true) {
    final params = {...filters, "limit": "100", "offset": "$offset"};
    final response = request != null
        ? await request(url, params)
        : await InvenTreeAPI().get(url, params: params);
    if (!response.successful() ||
        (!response.isList() && !response.isMap()) ||
        (response.isMap() && response.asMap()["results"] is! List)) {
      throw StateError("Inventory lookup failed (${response.statusCode})");
    }
    final page = response.resultsList();
    rows.addAll(page.map((row) => Map<String, dynamic>.from(row as Map)));
    if (response.isList() || response.asMap()["next"] == null) break;
    if (page.isEmpty) throw StateError("Invalid inventory pagination");
    offset += page.length;
  }
  return rows;
}
