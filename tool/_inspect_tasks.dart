import 'dart:io';
import 'package:excel/excel.dart';

String cellText(Data? cell) {
  final value = cell?.value;
  if (value == null) return '';
  return value.toString().trim();
}

void main() {
  final path = r'C:\Users\Barbara\Desktop\Spremanje\Arbeitsabläufe_Gold34.xlsx';
  final excel = Excel.decodeBytes(File(path).readAsBytesSync());
  stdout.writeln('SHEETS: ' + excel.tables.keys.join(', '));
  for (final sheetName in excel.tables.keys.take(3)) {
    final table = excel.tables[sheetName]!;
    stdout.writeln('\nSHEET ' + sheetName + ' rows=' + table.maxRows.toString() + ' cols=' + table.maxColumns.toString());
    for (var r = 0; r < table.maxRows && r < 12; r++) {
      final row = table.rows[r];
      final vals = <String>[];
      for (var c = 0; c < row.length && c < 18; c++) {
        vals.add(cellText(row[c]));
      }
      stdout.writeln('R: ' + vals.join(' | '));
    }
    final headers = <String>[];
    if (table.maxRows >= 4) {
      final row4 = table.rows[3];
      for (var c = 0; c < row4.length; c++) {
        final text = cellText(row4[c]);
        if (text.isNotEmpty) {
          headers.add('=');
        }
      }
    }
    stdout.writeln('ROW4: ' + headers.join(' || '));
    final found = <String>[];
    for (var r = 0; r < table.maxRows; r++) {
      final row = table.rows[r];
      for (var c = 0; c < row.length; c++) {
        final text = cellText(row[c]);
        if (text.toLowerCase().contains('unterschrift')) {
          found.add('RC=');
        }
      }
    }
    stdout.writeln('UNTERSCHRIFT sample: ' + found.take(40).join(' || '));
  }
}
