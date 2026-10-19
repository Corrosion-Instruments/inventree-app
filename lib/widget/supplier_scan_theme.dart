import "package:flutter/material.dart";

ThemeData supplierScanTheme(ThemeData inherited) => inherited.copyWith(
  textTheme: inherited.textTheme.apply(fontFamily: "Public Sans"),
  primaryTextTheme: inherited.primaryTextTheme.apply(fontFamily: "Public Sans"),
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
