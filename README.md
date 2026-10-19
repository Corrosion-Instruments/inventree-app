# InvenTree Mobile App

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![Android](https://github.com/inventree/inventree-app/actions/workflows/android.yaml/badge.svg)
![iOS](https://github.com/inventree/inventree-app/actions/workflows/ios.yaml/badge.svg)
[![Coverage Status](https://coveralls.io/repos/github/inventree/inventree-app/badge.svg?branch=master)](https://coveralls.io/github/inventree/inventree-app?branch=master)

The InvenTree mobile / tablet application is a companion app for the [InvenTree stock management system](https://github.com/inventree/InvenTree).

Written in the [Flutter](https://flutter.dev/) environment, the app provides native support for Android and iOS devices.

<p align="center">
  <img width="30%" src="https://github.com/user-attachments/assets/aee96f90-2953-47f6-916a-06f19d3b8aa5">
</p>

## Installation

You can install the app via the following channels:

### Google Play Store (Android)

Download and install from the [Google Play Store](https://play.google.com/store/apps/details?id=inventree.inventree_app&hl=en_AU)

### Apple Store (iOS)

Download and install from the [Apple App Store](https://apps.apple.com/au/app/inventree/id1581731101)

### Direct Download (Android)

We provide direct downloads for Android users - view our [download page via polar.sh](https://buy.polar.sh/polar_cl_UnGILJ0c7P3hQrOrJs127oyLTTDOTHKrnqfCg30XtBI)

## User Documentation

User documentation for the InvenTree mobile app can be found [within the InvenTree documentation](https://inventree.readthedocs.io/en/latest/app/app/).

## Developer Documentation

Refer to the [build instructions](BUILDING.md) for information on how to build the app from source.

## Supplier Scan

Open **Supplier Scan** from the home screen or side menu. Scan a DigiKey ECIA
2D label or an LCSC/JLC label, or paste its contents and tap **Find part**.
The screen shows the supplier SKU, MPN, label quantity and matching inventory
parts. Tap a result to open the existing part; multiple exact matches remain
available for selection. Camera, keyboard and intent scanners use the app's
configured scanner settings. The general barcode scanner also supports these
labels and opens matched parts directly.

Lookup checks supplier SKU, manufacturer MPN, then exact part name or IPN
(ignoring case). It uses the current server profile's authenticated inventory
API, supports paginated results, and requires no Supplier Scan server plugin
or DigiKey API credentials. It does not change stock. Other barcode actions,
including receiving and assigning barcodes, keep their existing handlers.

To receive stock, scan or paste a label and choose **Preview receiving**, review
the quantity and stock location, then tap **Receive stock**. Stock add permission
is required. The native receiving form uses the installed Supplier Scan server
plugin (0.1.3 or later), including its configured supplier, category suggestions,
new part/supplier record creation, metadata import and duplicate barcode checks.
Choose an existing part or a category when the label has no resolved part. Supplier
API credentials remain on the server. Finding parts still works without the plugin.

Receiving uses the app's current authenticated server profile and the plugin's
normal CSRF cookie/header handshake. The app always waits for **Receive stock**,
including when the web plugin's Auto Create setting is enabled. Previously received
labels require an explicit additional-stock choice. If a receipt cannot be confirmed
after a connection or server failure, refresh the preview and check the stock before
resubmitting; the app never retries a receive POST automatically. Successful receipts
show the created stock item and any supplier metadata import warnings.

The app has no runtime system for installing native UI plugins. InvenTree
server barcode plugins can also supply scan results through the barcode API;
native features such as this one ship in an app build. The Supplier Scan screen
bundles Public Sans from uswds/public-sans revision
`bae8aade44a1c1a2fdfeaabbfd6b6710b111a3a6`; its license files are included in
`assets/fonts/public-sans/` and the app's license assets.

Run `flutter test test/digikey_test.dart test/supplier_scan_test.dart test/supplier_receive_test.dart test/wedge_scanner_test.dart`
to check label decoding, matching, pagination, native scanning, receiving forms,
the authenticated receiving transport and duplicate/error handling.
