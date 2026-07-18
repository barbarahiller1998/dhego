import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:universal_html/html.dart' as html;

import 'app_globals.dart';

Widget buildWebStoragePhotoView({
  required String imageUrl,
  required double? width,
  required double? height,
  required BoxFit fit,
}) {
  final viewType =
      'dhego-storage-image-${imageUrl.hashCode}-${width ?? 0}-${height ?? 0}-${fit.name}';

  if (!registeredWebImageViewTypes.contains(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (viewId) {
      final image = html.ImageElement()
        ..src = imageUrl
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = switch (fit) {
          BoxFit.contain => 'contain',
          BoxFit.cover => 'cover',
          BoxFit.fill => 'fill',
          BoxFit.fitHeight => 'scale-down',
          BoxFit.fitWidth => 'scale-down',
          BoxFit.none => 'none',
          BoxFit.scaleDown => 'scale-down',
        };
      return image;
    });
    registeredWebImageViewTypes.add(viewType);
  }

  return SizedBox(
    width: width,
    height: height,
    child: HtmlElementView(viewType: viewType),
  );
}
