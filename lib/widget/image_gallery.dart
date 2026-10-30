import "dart:math" as math;

import "package:cached_network_image/cached_network_image.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:inventree/api.dart";
import "package:inventree/inventree/image_gallery.dart";
import "package:inventree/inventree/part.dart";
import "package:inventree/widget/part/part_detail.dart";

typedef GalleryImageBuilder = Widget Function(String source);

/// Native gallery, using the current server profile and the Parts permission.
class ImageGalleryWidget extends StatefulWidget {
  const ImageGalleryWidget({
    super.key,
    this.loadImages,
    this.imageBuilder,
    this.openPart,
  });

  final Future<List<GalleryImage>> Function()? loadImages;
  final GalleryImageBuilder? imageBuilder;
  final Future<void> Function(BuildContext context, int pk)? openPart;

  @override
  State<ImageGalleryWidget> createState() => _ImageGalleryWidgetState();
}

class _ImageGalleryWidgetState extends State<ImageGalleryWidget> {
  final _search = TextEditingController();
  List<GalleryImage> _images = [];
  bool _loading = true;
  bool _showJlcpcb = false;
  bool _openingPart = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final images = await (widget.loadImages?.call() ?? loadGalleryImages());
      if (mounted) setState(() => _images = images);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              "Could not load images. Check your connection and Parts access, then retry.",
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openPart(BuildContext sourceContext, int pk) async {
    if (_openingPart) return;
    _openingPart = true;
    try {
      if (widget.openPart != null) {
        await widget.openPart!(sourceContext, pk);
      } else {
        final part = await InvenTreePart().get(pk);
        if (!sourceContext.mounted) return;
        if (part is! InvenTreePart) throw StateError("Part unavailable");
        await Navigator.of(
          sourceContext,
        ).push(MaterialPageRoute(builder: (context) => PartDetailWidget(part)));
      }
    } catch (_) {
      if (sourceContext.mounted) {
        ScaffoldMessenger.of(sourceContext).showSnackBar(
          const SnackBar(
            content: Text("Could not open this part. Please try again."),
          ),
        );
      }
    } finally {
      _openingPart = false;
    }
  }

  Future<void> _copy(BuildContext sourceContext, String filename) async {
    try {
      await Clipboard.setData(ClipboardData(text: filename));
      if (sourceContext.mounted) {
        ScaffoldMessenger.of(
          sourceContext,
        ).showSnackBar(const SnackBar(content: Text("Filename copied")));
      }
    } catch (_) {
      if (sourceContext.mounted) {
        ScaffoldMessenger.of(sourceContext).showSnackBar(
          const SnackBar(content: Text("Could not copy filename")),
        );
      }
    }
  }

  Widget _image(String source) {
    if (widget.imageBuilder != null) return widget.imageBuilder!(source);
    final api = InvenTreeAPI();
    final uri = galleryMediaUri(source, api.makeUrl(""));
    if (uri == null) {
      return const Center(child: Icon(Icons.broken_image_outlined));
    }
    return CachedNetworkImage(
      imageUrl: uri.toString(),
      httpHeaders: api.defaultHeaders(),
      cacheManager: api.imageCacheManager,
      fit: BoxFit.contain,
      placeholder: (context, url) =>
          const Center(child: CircularProgressIndicator()),
      errorWidget: (context, url, error) =>
          const Center(child: Icon(Icons.broken_image_outlined)),
    );
  }

  void _preview(BuildContext context, GalleryImage image) {
    showDialog<void>(
      context: context,
      useSafeArea: false,
      builder: (context) => Dialog.fullscreen(
        child: ScaffoldMessenger(
          child: Builder(
            builder: (context) => Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  tooltip: "Close image",
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                title: Text(
                  image.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: [
                  IconButton(
                    tooltip: "Copy filename",
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () => _copy(context, image.filename),
                  ),
                ],
              ),
              body: SafeArea(
                child: Column(
                  children: [
                    Expanded(
                      child: InteractiveViewer(
                        minScale: 1,
                        maxScale: 6,
                        child: SizedBox.expand(child: _image(image.image)),
                      ),
                    ),
                    const Divider(height: 1),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.3,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: image.parts.length,
                        itemBuilder: (context, index) {
                          final part = image.parts[index];
                          return ListTile(
                            title: Text(part.name),
                            subtitle: part.ipn.isEmpty ? null : Text(part.ipn),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _openPart(context, part.pk),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, GalleryImage image) {
    final part = image.parts.first;
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: "Preview ${image.filename}",
              child: InkWell(
                onTap: () => _preview(context, image),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: SizedBox.expand(
                    child: _image(
                      image.thumbnail.isEmpty ? image.image : image.thumbnail,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    image.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  tooltip: "Copy filename",
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  onPressed: () => _copy(context, image.filename),
                ),
              ],
            ),
          ),
          InkWell(
            onTap: () => _openPart(context, part.pk),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: MediaQuery.textScalerOf(context).scale(
                      (theme.textTheme.titleSmall?.fontSize ?? 14) *
                          (theme.textTheme.titleSmall?.height ?? 1.5) *
                          2,
                    ),
                    child: Text(
                      part.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    part.ipn.isEmpty ? "Part #${part.pk}" : part.ipn,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              image.parts.length > 1
                  ? "${image.parts.length} linked parts · Tap image to view"
                  : image.isJlcpcb
                  ? "JLCPCB"
                  : " ",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inherited = Theme.of(context);
    return Theme(
      data: inherited.copyWith(
        textTheme: inherited.textTheme.apply(fontFamily: "Public Sans"),
        primaryTextTheme: inherited.primaryTextTheme.apply(
          fontFamily: "Public Sans",
        ),
      ),
      child: Builder(builder: _buildGallery),
    );
  }

  Widget _buildGallery(BuildContext context) {
    final visible = _images
        .where(
          (image) =>
              (_showJlcpcb || !image.isJlcpcb) && image.matches(_search.text),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text("Image Gallery"),
        actions: [
          IconButton(
            tooltip: "Refresh images",
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context);
            final minWidth = 150.0 + math.max(0, scale.scale(90) - 90);
            final columns = math.max(
              1,
              ((constraints.maxWidth - 20) / (minWidth + 12)).floor(),
            );
            final width =
                (constraints.maxWidth - 32 - (columns - 1) * 12) / columns;
            // Reserve equal text slots, including enlarged accessibility text.
            final height = width + 132 + scale.scale(72);
            return RefreshIndicator(
              onRefresh: _loading ? () async {} : _load,
              child: CustomScrollView(
                key: const PageStorageKey("image-gallery"),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: "Search images",
                          hintText: "Filename, part name or IPN",
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: "Clear search",
                                  onPressed: () => setState(_search.clear),
                                  icon: const Icon(Icons.close),
                                ),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SwitchListTile(
                      title: const Text("JLCPCB"),
                      subtitle: const Text(
                        "Include supplier images, shown last",
                      ),
                      value: _showJlcpcb,
                      onChanged: (value) => setState(() => _showJlcpcb = value),
                    ),
                  ),
                  if (_loading)
                    const SliverToBoxAdapter(child: LinearProgressIndicator()),
                  if (_error != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(child: Text(_error!)),
                            TextButton(
                              onPressed: _load,
                              child: const Text("Retry"),
                            ),
                          ],
                        ),
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text("${visible.length} images"),
                    ),
                  ),
                  if (visible.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            _loading
                                ? "Loading images…"
                                : _error != null
                                ? "Images are unavailable."
                                : "No images found.",
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      sliver: SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: width / height,
                        ),
                        itemCount: visible.length,
                        itemBuilder: (context, index) =>
                            _card(context, visible[index]),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
