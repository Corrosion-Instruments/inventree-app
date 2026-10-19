import "package:flutter/material.dart";
import "package:inventree/barcode/handler.dart";

/// Capture a label locally; decoding and lookup happen on the supplier screen.
class SupplierBarcodeCaptureHandler extends BarcodeHandler {
  SupplierBarcodeCaptureHandler(this.onCaptured);

  final ValueChanged<String> onCaptured;
  bool _captured = false;

  @override
  String getOverlayText(BuildContext context) =>
      "Scan a DigiKey, LCSC or JLC label";

  @override
  Future<void> processBarcode(
    String barcode, {
    String url = "barcode/",
    Map<String, dynamic> extra_data = const {},
  }) async {
    if (_captured || barcode.trim().isEmpty) return;
    _captured = true;
    onCaptured(barcode.trim());
  }
}
