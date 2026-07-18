import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  if (options == null) {
    _printUsage();
    exitCode = 64;
    return;
  }

  final inputFile = File(options.inputPath);
  if (!inputFile.existsSync()) {
    stderr.writeln('Excel file not found: ${inputFile.path}');
    exitCode = 66;
    return;
  }

  final excel = Excel.decodeBytes(inputFile.readAsBytesSync());
  final records = <Map<String, dynamic>>[];

  for (final sheetName in excel.tables.keys) {
    final table = excel.tables[sheetName];
    if (table == null) {
      continue;
    }

    final state = _CategoryState();
    for (final row in table.rows) {
      if (row.isEmpty) {
        continue;
      }

      final columnA = _cellText(row, 0);
      final columnB = _cellText(row, 1);
      final supplier = _cellText(row, 2);

      if (_looksLikeHeader(columnA, columnB, supplier)) {
        continue;
      }

      if (columnA.isEmpty && columnB.isEmpty && supplier.isEmpty) {
        continue;
      }

      if (_isCategoryRow(columnA, columnB, supplier)) {
        final categoryValue = columnB.trim().isNotEmpty
            ? columnB.trim()
            : columnA.trim();
        final fillHex = _normalizedFillHex(row, 1) ?? _normalizedFillHex(row, 0);
        state.applyCategory(categoryValue, fillHex);
        continue;
      }

      final articleNumber = columnA;
      final categoryValue = columnB;
      if (articleNumber.isEmpty || categoryValue.isEmpty) {
        continue;
      }

      final name = categoryValue.trim();
      state.markItem();
      records.add(<String, dynamic>{
        'id': _buildMaterialId(
          sheetName: sheetName,
          articleNumber: articleNumber,
          name: name,
        ),
        'name': name,
        'active': true,
        'articleNumber': articleNumber.trim(),
        'supplier': supplier.trim(),
        'sheetName': sheetName.trim(),
        'categorySheet': sheetName.trim(),
        'level1': state.level1,
        'level2': state.level2,
        'level3': state.level3,
        'level4': state.level4,
        'orangeCategory': state.level1,
        'greenCategory': state.level2,
        'blueCategory': state.level3,
        'purpleCategory': state.level4,
      });
    }
  }

  final outputFile = File(options.outputPath);
  outputFile.parent.createSync(recursive: true);
  outputFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'materials': records,
    }),
  );

  stdout.writeln(
    'Offline import file created: ${outputFile.path} '
    '(${records.length} materials).',
  );
  stdout.writeln(
    'When you are online, upload it with:\n'
    'dart run tool/firestore_import.dart --credentials <service-account.json> '
    '--data ${outputFile.path}',
  );
}

_Options? _parseArgs(List<String> args) {
  String? inputPath;
  var outputPath = 'seed/materials_offline.json';

  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    switch (arg) {
      case '--input':
        if (index + 1 >= args.length) {
          return null;
        }
        inputPath = args[++index];
      case '--output':
        if (index + 1 >= args.length) {
          return null;
        }
        outputPath = args[++index];
      default:
        return null;
    }
  }

  if (inputPath == null || inputPath.trim().isEmpty) {
    return null;
  }

  return _Options(inputPath: inputPath, outputPath: outputPath);
}

void _printUsage() {
  stdout.writeln(
    'Usage:\n'
    '  dart run tool/material_catalog_import.dart '
    '--input "<materials.xlsx>" '
    '[--output "seed/materials_offline.json"]',
  );
}

String _cellText(List<Data?> row, int index) {
  if (index >= row.length) {
    return '';
  }

  final cell = row[index];
  final value = cell?.value;
  if (value == null) {
    return '';
  }

  return switch (value) {
    TextCellValue() => value.toString().trim(),
    IntCellValue() => value.value.toString(),
    DoubleCellValue() => value.value.toString(),
    BoolCellValue() => value.value ? 'true' : 'false',
    FormulaCellValue() => value.formula.trim(),
    DateCellValue() => value.asDateTimeLocal().toIso8601String(),
    DateTimeCellValue() => value.asDateTimeLocal().toIso8601String(),
    TimeCellValue() => value.asDuration().toString(),
  };
}

String? _normalizedFillHex(List<Data?> row, int index) {
  if (index >= row.length) {
    return null;
  }

  final cell = row[index];
  final colorHex = cell?.cellStyle?.backgroundColor.colorHex ?? '';
  final normalized = colorHex.toUpperCase().replaceAll('#', '').trim();
  if (normalized.isEmpty || normalized == 'NONE') {
    return null;
  }

  return normalized;
}

bool _looksLikeHeader(
  String articleNumber,
  String categoryValue,
  String supplier,
) {
  return articleNumber.toLowerCase() == 'artikelnummer' &&
      categoryValue.toLowerCase() == 'kategorie' &&
      supplier.toLowerCase() == 'lieferant';
}

bool _isCategoryRow(String columnA, String columnB, String supplier) {
  if (supplier.trim().isNotEmpty) {
    return false;
  }

  final hasA = columnA.trim().isNotEmpty;
  final hasB = columnB.trim().isNotEmpty;

  if (hasA && !hasB) {
    return true;
  }

  if (!hasA && hasB) {
    return true;
  }

  return false;
}

String _buildMaterialId({
  required String sheetName,
  required String articleNumber,
  required String name,
}) {
  final articleSlug = _slugify(articleNumber);
  if (articleSlug.isNotEmpty) {
    return '${_slugify(sheetName)}.$articleSlug';
  }

  return '${_slugify(sheetName)}.${_slugify(name)}';
}

String _slugify(String value) {
  final lower = value
      .toLowerCase()
      .trim()
      .replaceAll('\u0161', 's')
      .replaceAll('\u0111', 'd')
      .replaceAll('\u010d', 'c')
      .replaceAll('\u0107', 'c')
      .replaceAll('\u017e', 'z')
      .replaceAll('\u00e4', 'a')
      .replaceAll('\u00f6', 'o')
      .replaceAll('\u00fc', 'u')
      .replaceAll('\u00df', 'ss');

  final buffer = StringBuffer();
  var previousWasSeparator = false;

  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    if (RegExp(r'[a-z0-9]').hasMatch(char)) {
      buffer.write(char);
      previousWasSeparator = false;
      continue;
    }

    if (!previousWasSeparator && buffer.isNotEmpty) {
      buffer.write('.');
      previousWasSeparator = true;
    }
  }

  return buffer.toString().replaceAll(RegExp(r'\.+$'), '');
}

class _CategoryState {
  String level1 = '';
  String level2 = '';
  String level3 = '';
  String level4 = '';
  int _lastCategoryDepth = 0;
  bool _sawItemSinceLastCategory = false;

  void applyCategory(String rawValue, String? fillHex) {
    final value = rawValue.trim();
    if (value.isEmpty) {
      return;
    }

    final explicitDepth = _depthFromFill(fillHex);
    final targetDepth = explicitDepth > 0
        ? explicitDepth
        : _implicitDepth();
    _setCategoryAtDepth(targetDepth, value);
    _lastCategoryDepth = targetDepth;
    _sawItemSinceLastCategory = false;
  }

  void markItem() {
    _sawItemSinceLastCategory = true;
  }

  int _implicitDepth() {
    if (_lastCategoryDepth == 0) {
      return _firstEmptyDepth();
    }

    if (_sawItemSinceLastCategory) {
      return _lastCategoryDepth.clamp(1, 4);
    }

    return (_lastCategoryDepth + 1).clamp(1, 4);
  }

  int _firstEmptyDepth() {
    if (level1.isEmpty) {
      return 1;
    }
    if (level2.isEmpty) {
      return 2;
    }
    if (level3.isEmpty) {
      return 3;
    }
    return 4;
  }

  void _setCategoryAtDepth(int depth, String value) {
    switch (depth) {
      case 1:
        level1 = value;
        level2 = '';
        level3 = '';
        level4 = '';
        return;
      case 2:
        level2 = value;
        level3 = '';
        level4 = '';
        return;
      case 3:
        level3 = value;
        level4 = '';
        return;
      default:
        level4 = value;
        return;
    }
  }

  int _depthFromFill(String? fillHex) {
    final fill = (fillHex ?? '').toUpperCase();
    if (fill.endsWith('FFC000')) {
      return 1;
    }
    if (fill.endsWith('92D050')) {
      return 2;
    }
    if (fill.endsWith('00B0F0') || fill.endsWith('5B9BD5')) {
      return 3;
    }
    if (fill.endsWith('7030A0') || fill.endsWith('8E44AD')) {
      return 4;
    }
    return 0;
  }
}

class _Options {
  const _Options({
    required this.inputPath,
    required this.outputPath,
  });

  final String inputPath;
  final String outputPath;
}
