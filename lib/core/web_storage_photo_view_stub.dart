import 'package:flutter/material.dart';

Widget buildWebStoragePhotoView({
  required String imageUrl,
  required double? width,
  required double? height,
  required BoxFit fit,
}) {
  return Image.network(imageUrl, width: width, height: height, fit: fit);
}
