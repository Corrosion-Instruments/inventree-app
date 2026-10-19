import "package:flutter/material.dart";
import "package:inventree/barcode/supplier_receiving.dart";
import "package:inventree/inventree/stock.dart";
import "package:inventree/widget/stock/stock_detail.dart";
import "package:inventree/widget/supplier_scan_theme.dart";

class SupplierReceiveWidget extends StatefulWidget {
  const SupplierReceiveWidget({
    super.key,
    required this.barcode,
    required this.canReceive,
    this.client,
    this.openStock,
  });
  final String barcode;
  final bool canReceive;
  final SupplierReceivingClient? client;
  final Future<void> Function(BuildContext, int)? openStock;

  @override
  State<SupplierReceiveWidget> createState() => _SupplierReceiveWidgetState();
}

class _SupplierReceiveWidgetState extends State<SupplierReceiveWidget> {
  late final _client = widget.client ?? SupplierReceivingClient.inventory();
  final _quantity = TextEditingController();
  final _search = TextEditingController();
  final _form = GlobalKey<FormState>();
  SupplierReceivingPreview? _preview;
  SupplierReceivingChoice? _duplicate;
  List<SupplierReceivingChoice> _parts = [];
  Map<String, dynamic>? _receipt;
  int? _partId;
  int? _categoryId;
  int? _locationId;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _searching = false;
  bool _openingStock = false;
  bool _allowDuplicate = false;
  bool _useImage = true;
  bool _needsRefresh = false;

  bool get _busy => _loading || _saving || _searching || _openingStock;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _quantity.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _preview = null;
    });
    try {
      final preview = await _client.preview(widget.barcode);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _duplicate = preview.duplicate;
        _parts = {
          for (final part in [
            if (preview.part != null) preview.part!,
            ...preview.candidates,
          ])
            part.pk: part,
        }.values.toList();
        _partId = preview.part?.pk;
        final suggested = preview.suggestedCategory?.pk;
        _categoryId = preview.categories.any((row) => row.pk == suggested)
            ? suggested
            : null;
        final location = preview.defaultLocation?.pk;
        _locationId = preview.locations.any((row) => row.pk == location)
            ? location
            : null;
        _quantity.text = "${preview.parsed['quantity'] ?? '1'}";
        _allowDuplicate = false;
        _useImage = "${preview.source['image_url'] ?? ''}".isNotEmpty;
        _needsRefresh = false;
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is SupplierReceivingException
              ? error.message
              : "Could not load the receiving preview. Try again.",
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _searchParts() async {
    if (_busy || _preview == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final found = await _client.searchParts(_search.text);
      if (!mounted) return;
      setState(() {
        _parts = {
          for (final part in [
            ..._parts.where((p) => p.pk == _partId),
            ...found,
          ])
            part.pk: part,
        }.values.toList();
        if (found.isEmpty) _error = "No parts found. Try another name or IPN.";
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = "Could not search parts. Try again.");
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _receive() async {
    if (_busy || _needsRefresh || _receipt != null || !widget.canReceive) {
      return;
    }
    if (!(_form.currentState?.validate() ?? false)) return;
    if (_duplicate != null && !_allowDuplicate) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await _client.receive(
        barcode: widget.barcode,
        quantity: _quantity.text,
        partId: _partId,
        categoryId: _categoryId,
        locationId: _locationId,
        allowDuplicate: _duplicate != null && _allowDuplicate,
        useSupplierImage: _useImage,
      );
      if (mounted) setState(() => _receipt = result);
    } on SupplierReceivingException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _needsRefresh = error.receiptUncertain;
          if (error.duplicate != null) {
            _duplicate = error.duplicate;
            _allowDuplicate = false;
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error =
              "The receipt could not be confirmed. Refresh the preview and check stock before trying again.";
          _needsRefresh = true;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openStock(int pk) async {
    if (_busy) return;
    setState(() => _openingStock = true);
    try {
      if (widget.openStock != null) {
        await widget.openStock!(context, pk);
      } else {
        final stock = await InvenTreeStockItem().get(pk);
        if (!mounted) return;
        if (stock is! InvenTreeStockItem) {
          throw StateError("Missing stock item");
        }
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => StockDetailWidget(stock)));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = "Could not open the stock item. Try again.");
      }
    } finally {
      if (mounted) setState(() => _openingStock = false);
    }
  }

  Widget _card(List<Widget> children) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );

  Widget _select({
    required String keyName,
    required String label,
    required String hint,
    required int? value,
    required List<SupplierReceivingChoice> choices,
    required ValueChanged<int?>? onChanged,
    String? Function(int?)? validator,
  }) => DropdownButtonFormField<int>(
    key: ValueKey("$keyName-$value"),
    initialValue: value,
    isExpanded: true,
    itemHeight: null,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
    hint: Text(hint, maxLines: 2, overflow: TextOverflow.ellipsis),
    selectedItemBuilder: (_) => [
      Text(hint, maxLines: 2, overflow: TextOverflow.ellipsis),
      for (final choice in choices)
        Text(choice.label, maxLines: 2, overflow: TextOverflow.ellipsis),
    ],
    items: [
      DropdownMenuItem<int>(child: Text(hint)),
      for (final choice in choices)
        DropdownMenuItem(
          value: choice.pk,
          child: Text(
            choice.label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
    onChanged: onChanged,
    validator: validator,
  );

  List<Widget> _previewFields(
    SupplierReceivingPreview preview,
    ThemeData theme,
  ) => [
    _card([
      Text(
        "${preview.parsed['supplier_name'] ?? 'Supplier'}",
        style: theme.textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      SelectableText("SKU: ${preview.parsed['sku']}"),
      SelectableText(
        "MPN: ${preview.source['mpn'] ?? preview.parsed['mpn'] ?? ''}",
      ),
      if ("${preview.source['name'] ?? ''}".isNotEmpty)
        Text("${preview.source['name']}"),
      if ("${preview.source['description'] ?? ''}".isNotEmpty)
        Text("${preview.source['description']}"),
      const SizedBox(height: 8),
      Text(
        preview.part == null
            ? "Choose an existing part or create a new part below."
            : "Existing part: ${preview.part!.label}",
      ),
      Text(
        "Supplier part: ${preview.supplierPart?.label ?? 'Will be created'}",
      ),
      if ("${preview.source['lookup_error'] ?? ''}".isNotEmpty)
        Text(
          "Supplier details unavailable: ${preview.source['lookup_error']}. Review the label details before receiving.",
        ),
      if (preview.source["lookup_status"] == "barcode")
        const Text(
          "Using label details. Rich DigiKey import uses the server's supplier API configuration.",
        ),
      if (preview.source["parameters"] is Map &&
          (preview.source["parameters"] as Map).isNotEmpty)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text("Supplier parameters"),
          children: [
            for (final entry in (preview.source["parameters"] as Map).entries)
              ListTile(
                dense: true,
                title: Text("${entry.key}"),
                subtitle: Text("${entry.value}"),
              ),
          ],
        ),
    ]),
    const SizedBox(height: 16),
    if (_duplicate != null) ...[
      _card([
        Text(
          "This label has already been received",
          style: theme.textTheme.titleMedium,
        ),
        Text(_duplicate!.label),
        TextButton(
          onPressed: _busy ? null : () => _openStock(_duplicate!.pk),
          child: const Text("View existing stock"),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _allowDuplicate,
          onChanged: _busy
              ? null
              : (value) => setState(() => _allowDuplicate = value ?? false),
          title: const Text("Receive this label again"),
          subtitle: const Text("Creates additional stock for the same label."),
        ),
      ]),
      const SizedBox(height: 16),
    ],
    _card([
      Text("Receiving details", style: theme.textTheme.titleMedium),
      const SizedBox(height: 16),
      if (preview.part == null) ...[
        TextField(
          key: const Key("receive-part-search"),
          controller: _search,
          readOnly: _busy,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _searchParts(),
          decoration: InputDecoration(
            labelText: "Search existing parts",
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: "Search parts",
              onPressed: _busy ? null : _searchParts,
              icon: const Icon(Icons.search),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _select(
          keyName: "receive-part",
          label: "Existing part",
          hint: "Create a new part",
          value: _partId,
          choices: _parts,
          onChanged: _busy ? null : (value) => setState(() => _partId = value),
        ),
        const SizedBox(height: 12),
        _select(
          keyName: "receive-category",
          label: "Category for new part",
          hint: "Choose a category",
          value: _categoryId,
          choices: preview.categories,
          onChanged: _busy || _partId != null
              ? null
              : (value) => setState(() => _categoryId = value),
          validator: (value) => _partId == null && value == null
              ? "Select a category or an existing part."
              : null,
        ),
        const SizedBox(height: 12),
      ],
      _select(
        keyName: "receive-location",
        label: "Stock location",
        hint:
            "Server default${preview.defaultLocation == null ? '' : ': ${preview.defaultLocation!.label}'}",
        value: _locationId,
        choices: preview.locations,
        onChanged: _busy
            ? null
            : (value) => setState(() => _locationId = value),
      ),
      const SizedBox(height: 12),
      TextFormField(
        key: const Key("receive-quantity"),
        controller: _quantity,
        readOnly: _busy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          labelText: "Quantity to receive",
          border: OutlineInputBorder(),
        ),
        validator: (value) => validSupplierReceiveQuantity(value ?? "")
            ? null
            : "Enter a quantity greater than zero.",
      ),
      if ("${preview.source['image_url'] ?? ''}".isNotEmpty)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _useImage,
          onChanged: _busy
              ? null
              : (value) => setState(() => _useImage = value ?? false),
          title: const Text("Import supplier photo"),
        ),
      const SizedBox(height: 16),
      const Text(
        "Creates a stock item and assigns this supplier label. Check the part, quantity and location before receiving.",
      ),
      const SizedBox(height: 12),
      if (!widget.canReceive)
        const Text("You need stock add permission to receive stock."),
      FilledButton.icon(
        key: const Key("receive-stock"),
        onPressed:
            _busy ||
                _needsRefresh ||
                !widget.canReceive ||
                (_duplicate != null && !_allowDuplicate)
            ? null
            : _receive,
        icon: const Icon(Icons.inventory_2_outlined),
        label: Text(_saving ? "Receiving…" : "Receive stock"),
      ),
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = supplierScanTheme(Theme.of(context));
    final preview = _preview;
    final receipt = _receipt;
    return Theme(
      data: theme,
      child: PopScope(
        canPop: !_saving,
        child: Scaffold(
          appBar: AppBar(title: const Text("Receive supplier stock")),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_busy) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 16),
                    ],
                    if (_error != null) ...[
                      Semantics(
                        liveRegion: true,
                        child: _card([
                          Text(
                            _error!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (receipt != null) ...[
                      Semantics(
                        liveRegion: true,
                        child: _card([
                          Text(
                            "Stock received",
                            style: theme.textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 12),
                          Text("Quantity: ${receipt['quantity']}"),
                          Text("${receipt['part']?['label'] ?? ''}"),
                          Text("${receipt['stock_item']['label']}"),
                          if (receipt["created_part"] == true)
                            const Text("Created a new inventory part."),
                          if (receipt["metadata_sync"]?["errors"] is List)
                            for (final error
                                in receipt["metadata_sync"]["errors"] as List)
                              Text("Stock was received; $error"),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _busy
                                ? null
                                : () => _openStock(
                                    receipt["stock_item"]["pk"] as int,
                                  ),
                            child: const Text("View received stock"),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => Navigator.pop(context),
                            child: const Text("Scan another label"),
                          ),
                        ]),
                      ),
                    ] else ...[
                      if (preview != null) ..._previewFields(preview, theme),
                      if (!_loading) ...[
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _busy ? null : _load,
                          child: const Text("Refresh preview"),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
