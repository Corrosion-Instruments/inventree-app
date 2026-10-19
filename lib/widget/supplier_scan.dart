import "package:flutter/material.dart";
import "package:flutter_tabler_icons/flutter_tabler_icons.dart";
import "package:inventree/barcode/barcode.dart";
import "package:inventree/barcode/digikey.dart";
import "package:inventree/barcode/supplier_capture.dart";
import "package:inventree/barcode/supplier_inventory.dart";
import "package:inventree/inventree/part.dart";
import "package:inventree/inventree/sentry.dart";
import "package:inventree/widget/part/part_detail.dart";

/// Native supplier lookup. It does not require the Supplier Scan web plugin.
class SupplierScanWidget extends StatefulWidget {
  const SupplierScanWidget({super.key, this.query, this.scan, this.openPart});

  final SupplierQuery? query;
  final Future<String?> Function(BuildContext context)? scan;
  final Future<void> Function(BuildContext context, int pk)? openPart;

  @override
  State<SupplierScanWidget> createState() => _SupplierScanWidgetState();
}

class _SupplierScanWidgetState extends State<SupplierScanWidget> {
  final _barcode = TextEditingController();
  SupplierBarcode? _parsed;
  List<SupplierPartMatch> _matches = [];
  String? _error;
  bool _loading = false;
  bool _scanning = false;
  bool _openingPart = false;
  bool _searched = false;

  bool get _busy => _loading || _scanning || _openingPart;

  @override
  void dispose() {
    _barcode.dispose();
    super.dispose();
  }

  void _resetResults() {
    setState(() {
      _parsed = null;
      _matches = [];
      _error = null;
      _searched = false;
    });
  }

  Future<void> _find() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final raw = _barcode.text.trim();
    final parsed = SupplierBarcode.parse(raw);
    setState(() {
      _parsed = parsed;
      _matches = [];
      _searched = false;
      _error = parsed != null
          ? null
          : raw.isEmpty
          ? "Scan or paste a supplier barcode first."
          : "Unsupported supplier label. Scan a DigiKey, LCSC or JLC 2D label.";
      _loading = parsed != null;
    });
    if (parsed == null) return;

    try {
      final matches = await SupplierPartLookup(
        widget.query ?? querySupplierInventory,
      ).find(parsed);
      if (!mounted) return;
      setState(() {
        _matches = matches;
        _searched = true;
      });
    } catch (error, stackTrace) {
      sentryReportError("SupplierScan.find", error, stackTrace);
      if (!mounted) return;
      setState(() {
        _error =
            "Could not look up this label. Check your connection and try again.";
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _scan() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() => _scanning = true);
    String? raw;
    try {
      if (widget.scan != null) {
        raw = await widget.scan!(context);
      } else {
        final result = await scanBarcode(
          context,
          handler: SupplierBarcodeCaptureHandler((barcode) {
            if (mounted) Navigator.of(context).pop(barcode);
          }),
        );
        if (result is String) raw = result;
      }
    } catch (error, stackTrace) {
      sentryReportError("SupplierScan.scan", error, stackTrace);
      if (mounted) {
        setState(
          () => _error =
              "Could not start the scanner. You can paste a label instead.",
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    if (!mounted || raw == null || raw.trim().isEmpty) return;
    _barcode.text = raw;
    await _find();
  }

  Future<void> _openPart(SupplierPartMatch match) async {
    if (_busy) return;
    setState(() => _openingPart = true);
    try {
      if (widget.openPart != null) {
        await widget.openPart!(context, match.pk);
      } else {
        final part = await InvenTreePart().get(match.pk);
        if (!mounted) return;
        if (part is! InvenTreePart) throw StateError("Part not available");
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (context) => PartDetailWidget(part)));
      }
    } catch (error, stackTrace) {
      sentryReportError("SupplierScan.openPart", error, stackTrace);
      if (mounted) {
        setState(() => _error = "Could not open this part. Try again.");
      }
    } finally {
      if (mounted) setState(() => _openingPart = false);
    }
  }

  Widget _labelSummary(ThemeData theme, SupplierBarcode parsed) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(parsed.supplierName, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText("SKU: ${parsed.sku}"),
            if (parsed.mpn.isNotEmpty) SelectableText("MPN: ${parsed.mpn}"),
            if (parsed.quantity.isNotEmpty)
              Text("Label quantity: ${parsed.quantity}"),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inherited = Theme.of(context);
    final theme = inherited.copyWith(
      textTheme: inherited.textTheme.apply(fontFamily: "Public Sans"),
      primaryTextTheme: inherited.primaryTextTheme.apply(
        fontFamily: "Public Sans",
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: inherited.brightness == Brightness.dark
              ? const Color(0xfff2f4f7)
              : const Color(0xff171717),
          foregroundColor: inherited.brightness == Brightness.dark
              ? const Color(0xff171717)
              : Colors.white,
        ),
      ),
    );
    final parsed = _parsed;
    return Theme(
      data: theme,
      child: Scaffold(
        appBar: AppBar(title: const Text("Supplier Scan")),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text("Find a part", style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                const Text(
                  "Scan a DigiKey, LCSC or JLC label to find it in inventory.",
                ),
                const SizedBox(height: 16),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          key: const Key("supplier-barcode"),
                          controller: _barcode,
                          readOnly: _busy,
                          minLines: 1,
                          maxLines: 3,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.search,
                          decoration: const InputDecoration(
                            labelText: "Supplier barcode",
                            hintText: "Scan or paste a label",
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => _resetResults(),
                          onSubmitted: (_) => _find(),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: _busy ? null : _scan,
                              icon: const Icon(TablerIcons.scan),
                              label: const Text("Scan label"),
                            ),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _find,
                              icon: const Icon(TablerIcons.search),
                              label: const Text("Find part"),
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () {
                                      _barcode.clear();
                                      _resetResults();
                                    },
                              child: const Text("Clear"),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Use your camera, connected scanner, or paste a label above.",
                          style: theme.textTheme.bodySmall,
                        ),
                        if (_loading || _openingPart) ...[
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            semanticsLabel: _loading
                                ? "Finding part"
                                : "Opening part",
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Card(
                      margin: EdgeInsets.zero,
                      color: theme.colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                if (parsed != null) ...[
                  const SizedBox(height: 16),
                  _labelSummary(theme, parsed),
                ],
                if (_searched) ...[
                  const SizedBox(height: 20),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _matches.isEmpty
                          ? "No matching part in inventory"
                          : _matches.length == 1
                          ? "Part found"
                          : "Choose a matching part (${_matches.length})",
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (_matches.isEmpty) ...[
                    const SizedBox(height: 8),
                    const Text(
                      "Check that the supplier SKU or manufacturer part number is linked to an inventory part.",
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    Card(
                      margin: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (
                            var index = 0;
                            index < _matches.length;
                            index++
                          ) ...[
                            if (index > 0) const Divider(height: 1),
                            ListTile(
                              key: Key("supplier-part-${_matches[index].pk}"),
                              leading: const Icon(TablerIcons.box),
                              title: Text(
                                _matches[index].label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                "Part #${_matches[index].pk}${_matches[index].description.isEmpty ? '' : ' · ${_matches[index].description}'}",
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: _busy
                                  ? null
                                  : () => _openPart(_matches[index]),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
