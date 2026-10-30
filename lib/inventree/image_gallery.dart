import "package:inventree/api.dart";

typedef GalleryRequest =
    Future<APIResponse> Function(String url, Map<String, String> params);

/// One part associated with a gallery image. Shared images keep all part links.
class GalleryPart {
  const GalleryPart({
    required this.pk,
    required this.name,
    this.ipn = "",
    this.description = "",
  });

  final int pk;
  final String name;
  final String ipn;
  final String description;
}

class GalleryImage {
  GalleryImage({
    required this.image,
    required this.thumbnail,
    required this.parts,
  });

  final String image;
  final String thumbnail;
  final List<GalleryPart> parts;

  String get filename => Uri.tryParse(image)?.pathSegments.lastOrNull ?? image;
  bool get isJlcpcb => filename.toLowerCase().startsWith("part-");

  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    return needle.isEmpty ||
        filename.toLowerCase().contains(needle) ||
        parts.any(
          (part) => [
            part.name,
            part.ipn,
            part.description,
          ].any((value) => value.toLowerCase().contains(needle)),
        );
  }
}

/// Read every page before grouping and sorting, so JLCPCB images are last
/// across the entire gallery. The standard Parts API enforces user permissions.
Future<List<GalleryImage>> loadGalleryImages({GalleryRequest? request}) async {
  final images = <String, GalleryImage>{};
  final seenParts = <int>{};
  var offset = 0;
  while (true) {
    // There is no has_image filter on older InvenTree servers.
    final params = {"limit": "100", "offset": "$offset", "ordering": "id"};
    final response = request != null
        ? await request("part/", params)
        : await InvenTreeAPI().get("part/", params: params);
    if (!response.successful() ||
        (!response.isList() && !response.isMap()) ||
        (response.isMap() && response.asMap()["results"] is! List)) {
      throw StateError("Image gallery lookup failed (${response.statusCode})");
    }
    final rows = response.resultsList();
    var newParts = 0;
    for (final row in rows) {
      if (row is! Map || row["pk"] is! int) {
        throw StateError("Invalid gallery part response");
      }
      final pk = row["pk"] as int;
      if (!seenParts.add(pk)) continue;
      newParts++;
      final image = row["image"]?.toString() ?? "";
      if (image.isEmpty) continue;
      final part = GalleryPart(
        pk: pk,
        name: row["name"]?.toString() ?? "Part $pk",
        ipn: row["IPN"]?.toString() ?? "",
        description: row["description"]?.toString() ?? "",
      );
      final entry = images.putIfAbsent(
        image,
        () => GalleryImage(
          image: image,
          thumbnail: row["thumbnail"]?.toString() ?? image,
          parts: [],
        ),
      );
      entry.parts.add(part);
    }
    if (response.isList() || response.asMap()["next"] == null) break;
    if (rows.isEmpty || newParts == 0) {
      throw StateError("Invalid gallery pagination");
    }
    offset += rows.length;
  }
  final result = images.values.toList();
  for (final image in result) {
    image.parts.sort((a, b) => a.pk.compareTo(b.pk));
  }
  result.sort((a, b) {
    if (a.isJlcpcb != b.isJlcpcb) return a.isJlcpcb ? 1 : -1;
    final name = a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
    return name != 0 ? name : a.image.compareTo(b.image);
  });
  return result;
}

/// Resolve media only against the selected server before attaching its token.
Uri? galleryMediaUri(String source, String server) {
  final base = Uri.tryParse(server);
  final path = Uri.tryParse(source);
  if (base == null ||
      path == null ||
      source.isEmpty ||
      !const ["https", "http"].contains(base.scheme) ||
      base.host.isEmpty) {
    return null;
  }
  final resolved = base.resolveUri(path);
  if (!const ["https", "http"].contains(resolved.scheme) ||
      resolved.origin != base.origin ||
      resolved.userInfo.isNotEmpty) {
    return null;
  }
  return resolved;
}
