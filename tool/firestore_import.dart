import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  if (options == null) {
    _printUsage();
    exitCode = 64;
    return;
  }

  final credentialsFile = File(options.credentialsPath);
  final dataFile = File(options.dataPath);

  if (!credentialsFile.existsSync()) {
    stderr.writeln('Credentials file not found: ${credentialsFile.path}');
    exitCode = 66;
    return;
  }

  if (!dataFile.existsSync()) {
    stderr.writeln('Data file not found: ${dataFile.path}');
    exitCode = 66;
    return;
  }

  final credentials = ServiceAccountCredentials.fromJson(
    jsonDecode(credentialsFile.readAsStringSync()) as Map<String, dynamic>,
  );

  final rawData =
      jsonDecode(dataFile.readAsStringSync()) as Map<String, dynamic>;

  final client = await clientViaServiceAccount(credentials, <String>[
    'https://www.googleapis.com/auth/datastore',
  ]);

  try {
    await _importData(
      client: client,
      projectId: options.projectId,
      rawData: rawData,
    );
    stdout.writeln('Import finished successfully.');
  } finally {
    client.close();
  }
}

Future<void> _importData({
  required http.Client client,
  required String projectId,
  required Map<String, dynamic> rawData,
}) async {
  for (final entry in rawData.entries) {
    final collectionName = entry.key;
    final documents = entry.value;

    if (documents is! List) {
      stderr.writeln(
        'Skipping "$collectionName" because it is not a list of documents.',
      );
      continue;
    }

    stdout.writeln('Importing collection: $collectionName');

    for (final rawDocument in documents) {
      if (rawDocument is! Map<String, dynamic>) {
        stderr.writeln(
          'Skipping a document in "$collectionName" because it is invalid.',
        );
        continue;
      }

      final documentId = rawDocument['id'] as String?;
      if (documentId == null || documentId.trim().isEmpty) {
        stderr.writeln(
          'Skipping a document in "$collectionName" because "id" is missing.',
        );
        continue;
      }

      final fields = Map<String, dynamic>.from(rawDocument)..remove('id');
      await _upsertDocument(
        client: client,
        projectId: projectId,
        collectionName: collectionName,
        documentId: documentId,
        fields: fields,
      );
      stdout.writeln('  Upserted $collectionName/$documentId');
    }
  }
}

Future<void> _upsertDocument({
  required http.Client client,
  required String projectId,
  required String collectionName,
  required String documentId,
  required Map<String, dynamic> fields,
}) async {
  final documentPath =
      'projects/$projectId/databases/(default)/documents/$collectionName/$documentId';
  final uri = Uri.https('firestore.googleapis.com', '/v1/$documentPath');

  final response = await client.patch(
    uri,
    headers: <String, String>{'Content-Type': 'application/json'},
    body: jsonEncode(<String, dynamic>{'fields': _encodeMap(fields)}),
  );

  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException(
      'Failed to import $collectionName/$documentId '
      '(HTTP ${response.statusCode}): ${response.body}',
    );
  }
}

Map<String, dynamic> _encodeMap(Map<String, dynamic> value) {
  return value.map(
    (key, item) => MapEntry<String, dynamic>(key, _encodeValue(item)),
  );
}

Map<String, dynamic> _encodeValue(dynamic value) {
  if (value == null) {
    return <String, dynamic>{'nullValue': null};
  }

  if (value is String) {
    return <String, dynamic>{'stringValue': value};
  }

  if (value is bool) {
    return <String, dynamic>{'booleanValue': value};
  }

  if (value is int) {
    return <String, dynamic>{'integerValue': value.toString()};
  }

  if (value is double) {
    return <String, dynamic>{'doubleValue': value};
  }

  if (value is List) {
    return <String, dynamic>{
      'arrayValue': <String, dynamic>{
        'values': value.map(_encodeValue).toList(),
      },
    };
  }

  if (value is Map<String, dynamic>) {
    return <String, dynamic>{
      'mapValue': <String, dynamic>{'fields': _encodeMap(value)},
    };
  }

  if (value is Map) {
    return <String, dynamic>{
      'mapValue': <String, dynamic>{
        'fields': _encodeMap(
          value.map(
            (key, item) => MapEntry<String, dynamic>(key.toString(), item),
          ),
        ),
      },
    };
  }

  throw UnsupportedError(
    'Unsupported value type: ${value.runtimeType} ($value)',
  );
}

_ImportOptions? _parseArgs(List<String> args) {
  String? credentialsPath;
  String? dataPath;
  String projectId = 'dhego-fb024';

  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    switch (arg) {
      case '--credentials':
        if (index + 1 >= args.length) {
          return null;
        }
        credentialsPath = args[++index];
      case '--data':
        if (index + 1 >= args.length) {
          return null;
        }
        dataPath = args[++index];
      case '--project':
        if (index + 1 >= args.length) {
          return null;
        }
        projectId = args[++index];
      default:
        return null;
    }
  }

  if (credentialsPath == null || dataPath == null) {
    return null;
  }

  return _ImportOptions(
    credentialsPath: credentialsPath,
    dataPath: dataPath,
    projectId: projectId,
  );
}

void _printUsage() {
  stdout.writeln(
    'Usage:\n'
    '  dart run tool/firestore_import.dart '
    '--credentials <service-account.json> '
    '--data <seed_data.json> '
    '[--project dhego-fb024]',
  );
}

class _ImportOptions {
  const _ImportOptions({
    required this.credentialsPath,
    required this.dataPath,
    required this.projectId,
  });

  final String credentialsPath;
  final String dataPath;
  final String projectId;
}
