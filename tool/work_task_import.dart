import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
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
  final inputFile = File(options.inputPath);
  if (!credentialsFile.existsSync()) {
    stderr.writeln('Credentials file not found: ${credentialsFile.path}');
    exitCode = 66;
    return;
  }
  if (!inputFile.existsSync()) {
    stderr.writeln('Workbook not found: ${inputFile.path}');
    exitCode = 66;
    return;
  }

  final credentials = ServiceAccountCredentials.fromJson(
    jsonDecode(credentialsFile.readAsStringSync()) as Map<String, dynamic>,
  );

  final client = await clientViaServiceAccount(credentials, <String>[
    'https://www.googleapis.com/auth/datastore',
  ]);

  try {
    final firestoreData = await _loadReferenceData(
      client: client,
      projectId: options.projectId,
    );
    final importResult = _parseWorkbook(
      workbookPath: inputFile.path,
      referenceData: firestoreData,
    );

    final output = <String, dynamic>{
      'projects': importResult.projects,
      'buildings': importResult.buildings,
      'wohnungs': importResult.wohnungs,
      'work_tasks': importResult.tasks,
    };

    final outputFile = File(options.outputPath);
    outputFile.parent.createSync(recursive: true);
    outputFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(output));

    stdout.writeln(
      'Task import file created: ${outputFile.path}\n'
      'Tasks: ${importResult.tasks.length}\n'
      'Wohnungs prepared: ${importResult.wohnungs.length}\n'
      'Buildings prepared: ${importResult.buildings.length}\n'
      'Projects prepared: ${importResult.projects.length}',
    );

    if (importResult.skipped.isNotEmpty) {
      stdout.writeln('\nSkipped rows (${importResult.skipped.length}):');
      for (final line in importResult.skipped.take(100)) {
        stdout.writeln(' - $line');
      }
      if (importResult.skipped.length > 100) {
        stdout.writeln(' - ... and ${importResult.skipped.length - 100} more');
      }
    }
  } finally {
    client.close();
  }
}

Future<_ReferenceData> _loadReferenceData({
  required http.Client client,
  required String projectId,
}) async {
  final projects = await _listCollection(
    client: client,
    projectId: projectId,
    collectionName: 'projects',
  );
  final buildings = await _listCollection(
    client: client,
    projectId: projectId,
    collectionName: 'buildings',
  );
  final wohnungs = await _listCollection(
    client: client,
    projectId: projectId,
    collectionName: 'wohnungs',
  );

  return _ReferenceData(
    projects: projects.map(_ProjectRef.fromDocument).toList(),
    buildings: buildings.map(_BuildingRef.fromDocument).toList(),
    wohnungs: wohnungs.map(_WohnungRef.fromDocument).toList(),
  );
}

Future<List<Map<String, dynamic>>> _listCollection({
  required http.Client client,
  required String projectId,
  required String collectionName,
}) async {
  final documents = <Map<String, dynamic>>[];
  String? pageToken;

  do {
    final query = <String, String>{'pageSize': '1000'};
    if (pageToken != null && pageToken.isNotEmpty) {
      query['pageToken'] = pageToken;
    }

    final uri = Uri.https(
      'firestore.googleapis.com',
      '/v1/projects/$projectId/databases/(default)/documents/$collectionName',
      query,
    );
    final response = await client.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Failed to load $collectionName (HTTP ${response.statusCode}): ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final docs = (decoded['documents'] as List<dynamic>? ?? <dynamic>[])
        .whereType<Map<String, dynamic>>();
    documents.addAll(docs);
    pageToken = decoded['nextPageToken']?.toString();
  } while (pageToken != null && pageToken.isNotEmpty);

  return documents;
}

_TaskImportResult _parseWorkbook({
  required String workbookPath,
  required _ReferenceData referenceData,
}) {
  final excel = Excel.decodeBytes(File(workbookPath).readAsBytesSync());
  final tasks = <Map<String, dynamic>>[];
  final skipped = <String>[];
  final projects = <String, Map<String, dynamic>>{};
  final buildings = <String, Map<String, dynamic>>{};
  final wohnungs = <String, Map<String, dynamic>>{};
  final buildingTotalPoints = <String, int>{};
  final projectTotalPoints = <String, int>{};
  final wohnungTotalPoints = <String, int>{};
  final importedAt = DateTime.now().toIso8601String();
  final workbookName = _deriveProjectName(workbookPath);
  final projectRef = referenceData.findOrCreateProject(workbookName);

  projects[projectRef.id] = <String, dynamic>{
    'id': projectRef.id,
    'name': projectRef.name,
    'managerId': projectRef.managerId,
    'managerName': projectRef.managerName,
    'managerEmail': projectRef.managerEmail,
    'active': true,
    'workTaskTotalPoints': 0,
    'workTaskCompletedPoints': 0,
    'workTaskProgressPercent': 0,
  };

  for (final sheetName in excel.tables.keys) {
    final table = excel.tables[sheetName];
    if (table == null || table.maxRows < 6) {
      continue;
    }

    final buildingRef = referenceData.findOrCreateBuilding(
      project: projectRef,
      sheetName: sheetName,
      titleCell: _rowCellText(table.rows, 0, 0),
    );
    buildings[buildingRef.id] = <String, dynamic>{
      'id': buildingRef.id,
      'projectId': buildingRef.projectId,
      'name': buildingRef.name,
      'active': true,
      'workTaskTotalPoints': 0,
      'workTaskCompletedPoints': 0,
      'workTaskProgressPercent': 0,
    };

    final processHeaders = _extractProcessHeaders(table.rows);
    for (var rowIndex = 5; rowIndex < table.maxRows; rowIndex++) {
      final row = table.rows[rowIndex];
      final rawApartment = _cellTextAt(row, 1);
      if (rawApartment.isEmpty) {
        continue;
      }

      final apartmentName = _formatApartmentName(rawApartment);
      var wohnungRef = referenceData.findOrCreateWohnung(
        buildingId: buildingRef.id,
        apartmentName: apartmentName,
        rawApartment: rawApartment,
      );
      wohnungs[wohnungRef.id] = <String, dynamic>{
        'id': wohnungRef.id,
        'buildingId': wohnungRef.buildingId,
        'name': wohnungRef.name,
        'active': true,
        'checklistType': wohnungRef.checklistType,
        'workTaskTotalPoints': 0,
        'workTaskCompletedPoints': 0,
        'workTaskProgressPercent': 0,
      };

      for (var columnIndex = 3; columnIndex < row.length; columnIndex++) {
        final value = _cellTextAt(row, columnIndex);
        final header = processHeaders[columnIndex] ?? const _TaskHeader();
        final taskGroup = header.group.trim();
        final taskType = header.type.trim();
        if (taskGroup.isEmpty && taskType.isEmpty) {
          continue;
        }

        final normalizedTaskGroup = _normalizeKey(taskGroup);
        String resolvedChecklistType = '';
        if (normalizedTaskGroup == 'register') {
          resolvedChecklistType = _normalizeChecklistType(value);
          if (resolvedChecklistType.isEmpty) {
            if (value.trim().isNotEmpty) {
              skipped.add(
                'Sheet "$sheetName" row ${rowIndex + 1} col ${columnIndex + 1}: invalid checklist type "$value" for Register.',
              );
            }
            continue;
          }
        } else if (!_isTaskMarker(value)) {
          continue;
        }

        final taskLabel = taskType.isEmpty || taskType == taskGroup
            ? taskGroup
            : '$taskGroup / $taskType';
        final taskId = _buildTaskId(
          buildingId: buildingRef.id,
          wohnungId: wohnungRef.id,
          taskGroup: taskGroup,
          taskType: taskType,
        );

        tasks.add(<String, dynamic>{
          'id': taskId,
          'projectId': buildingRef.projectId,
          'projectName': buildingRef.projectName,
          'buildingId': buildingRef.id,
          'buildingName': buildingRef.name,
          'wohnungId': wohnungRef.id,
          'apartmentName': apartmentName,
          'rawApartment': rawApartment.trim(),
          'sheetName': sheetName,
          'taskGroup': taskGroup,
          'taskType': taskType,
          'taskLabel': taskLabel,
          'pointValue': 1,
          'completed': false,
          'completedAt': '',
          'completedBy': '',
          'active': true,
          'sortOrder': columnIndex - 2,
          'sourceRow': rowIndex + 1,
          'sourceColumn': columnIndex + 1,
          'importedAt': importedAt,
        });

        if (resolvedChecklistType.isNotEmpty &&
            wohnungRef.checklistType != resolvedChecklistType) {
          wohnungRef = wohnungRef.withChecklistType(resolvedChecklistType);
          wohnungs[wohnungRef.id] = <String, dynamic>{
            ...?wohnungs[wohnungRef.id],
            'id': wohnungRef.id,
            'buildingId': wohnungRef.buildingId,
            'name': wohnungRef.name,
            'active': true,
            'checklistType': wohnungRef.checklistType,
            'workTaskTotalPoints': wohnungs[wohnungRef.id]?['workTaskTotalPoints'] ?? 0,
            'workTaskCompletedPoints':
                wohnungs[wohnungRef.id]?['workTaskCompletedPoints'] ?? 0,
            'workTaskProgressPercent':
                wohnungs[wohnungRef.id]?['workTaskProgressPercent'] ?? 0,
          };
        }

        buildingTotalPoints[buildingRef.id] =
            (buildingTotalPoints[buildingRef.id] ?? 0) + 1;
        projectTotalPoints[buildingRef.projectId] =
            (projectTotalPoints[buildingRef.projectId] ?? 0) + 1;
        wohnungTotalPoints[wohnungRef.id] =
            (wohnungTotalPoints[wohnungRef.id] ?? 0) + 1;
      }
    }
  }

  for (final entry in buildingTotalPoints.entries) {
    buildings[entry.key]?['workTaskTotalPoints'] = entry.value;
  }
  for (final entry in projectTotalPoints.entries) {
    projects[entry.key]?['workTaskTotalPoints'] = entry.value;
  }
  for (final entry in wohnungTotalPoints.entries) {
    wohnungs[entry.key]?['workTaskTotalPoints'] = entry.value;
  }

  final existingTaskIds = tasks
      .map((entry) => entry['id']?.toString() ?? '')
      .where((value) => value.isNotEmpty)
      .toSet();
  for (final wohnungEntry in wohnungs.values) {
    final wohnungId = wohnungEntry['id']?.toString() ?? '';
    final buildingId = wohnungEntry['buildingId']?.toString() ?? '';
    if (wohnungId.isEmpty || buildingId.isEmpty) {
      continue;
    }
    final building = buildings[buildingId];
    if (building == null) {
      continue;
    }
    final projectId = building['projectId']?.toString() ?? '';
    final projectName = building['projectName']?.toString() ?? '';
    final druckprobeTaskId = _buildTaskId(
      buildingId: buildingId,
      wohnungId: wohnungId,
      taskGroup: 'Druckprobe',
      taskType: '',
    );
    if (existingTaskIds.contains(druckprobeTaskId)) {
      continue;
    }

    tasks.add(<String, dynamic>{
      'id': druckprobeTaskId,
      'projectId': projectId,
      'projectName': projectName,
      'buildingId': buildingId,
      'buildingName': building['name']?.toString() ?? '',
      'wohnungId': wohnungId,
      'apartmentName': wohnungEntry['name']?.toString() ?? '',
      'rawApartment': wohnungEntry['name']?.toString() ?? '',
      'sheetName': building['name']?.toString() ?? '',
      'taskGroup': 'Druckprobe',
      'taskType': '',
      'taskLabel': 'Druckprobe',
      'pointValue': 1,
      'completed': false,
      'completedAt': '',
      'completedBy': '',
      'active': true,
      'sortOrder': 999,
      'sourceRow': 0,
      'sourceColumn': 999,
      'importedAt': importedAt,
    });
    existingTaskIds.add(druckprobeTaskId);
    buildingTotalPoints[buildingId] = (buildingTotalPoints[buildingId] ?? 0) + 1;
    projectTotalPoints[projectId] = (projectTotalPoints[projectId] ?? 0) + 1;
    wohnungTotalPoints[wohnungId] = (wohnungTotalPoints[wohnungId] ?? 0) + 1;
    buildings[buildingId]?['workTaskTotalPoints'] = buildingTotalPoints[buildingId];
    projects[projectId]?['workTaskTotalPoints'] = projectTotalPoints[projectId];
    wohnungs[wohnungId]?['workTaskTotalPoints'] = wohnungTotalPoints[wohnungId];
  }

  return _TaskImportResult(
    projects: projects.values.toList(),
    buildings: buildings.values.toList(),
    wohnungs: wohnungs.values.toList(),
    tasks: tasks,
    skipped: skipped,
  );
}

Map<int, _TaskHeader> _extractProcessHeaders(List<List<Data?>> rows) {
  final headers = <int, _TaskHeader>{};
  if (rows.length < 5) {
    return headers;
  }

  final row4 = rows[3];
  final row5 = rows[4];
  String currentGroup = '';

  final maxColumns = row4.length > row5.length ? row4.length : row5.length;
  for (var columnIndex = 3; columnIndex < maxColumns; columnIndex++) {
    final groupText = _cellTextAt(row4, columnIndex);
    final typeText = _cellTextAt(row5, columnIndex);
    if (groupText.isNotEmpty) {
      currentGroup = groupText;
    }
    if (currentGroup.isEmpty && typeText.isEmpty) {
      continue;
    }
    headers[columnIndex] = _TaskHeader(group: currentGroup, type: typeText);
  }

  return headers;
}

String _rowCellText(List<List<Data?>> rows, int rowIndex, int columnIndex) {
  if (rowIndex >= rows.length) {
    return '';
  }
  return _cellTextAt(rows[rowIndex], columnIndex);
}

String _cellTextAt(List<Data?> row, int index) {
  if (index >= row.length) {
    return '';
  }
  return _cellText(row[index], 0);
}

String _cellText(Data? cell, int _) {
  final value = cell?.value;
  if (value == null) {
    return '';
  }

  return switch (value) {
    TextCellValue() => _repairImportedText(
      value.toString().replaceAll('\n', ' ').trim(),
    ),
    IntCellValue() => value.value.toString(),
    DoubleCellValue() => value.value.toString(),
    BoolCellValue() => value.value ? 'true' : 'false',
    FormulaCellValue() => _repairImportedText(value.formula.trim()),
    DateCellValue() => value.asDateTimeLocal().toIso8601String(),
    DateTimeCellValue() => value.asDateTimeLocal().toIso8601String(),
    TimeCellValue() => value.asDuration().toString(),
  };
}

String _repairImportedText(String text) {
  if (!text.contains('Ã') &&
      !text.contains('Â') &&
      !text.contains('¤') &&
      !text.contains('¼') &&
      !text.contains('¶')) {
    return text;
  }

  try {
    return utf8.decode(latin1.encode(text));
  } catch (_) {
    return text;
  }
}

bool _isTaskMarker(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized == 'true' ||
      normalized == '1' ||
      normalized == 'x' ||
      normalized == '✓' ||
      normalized == '✔' ||
      normalized == 'ja' ||
      normalized == 'yes' ||
      normalized == 'wahr' ||
      normalized == 'unterschrift';
}

String _normalizeChecklistType(String value) {
  final normalized = _normalizeKey(value);
  switch (normalized) {
    case 'medientrager':
      return 'Medientrager';
    case 'strang':
      return 'Strang';
    case 'strangseiten':
      return 'Strang+Seiten';
    default:
      return '';
  }
}

String _formatApartmentName(String rawApartment) {
  final cleaned = rawApartment.trim();
  final withoutPrefix = cleaned.replaceFirst(
    RegExp(r'^(we|wohnung)\s*', caseSensitive: false),
    '',
  );
  return 'WE${withoutPrefix.toUpperCase()}';
}

String _deriveProjectName(String workbookPath) {
  final fileName = workbookPath.split(Platform.pathSeparator).last;
  final withoutExtension = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
  final trimmed = withoutExtension
      .replaceFirst(RegExp(r'^arbeitsabl[aä]ufe[_\s-]*', caseSensitive: false), '')
      .replaceAll('_', ' ')
      .trim();
  final goldMatch = RegExp(r'^([A-Za-z]+)\s*(\d)\s*(\d)$').firstMatch(trimmed);
  if (goldMatch != null) {
    return '${goldMatch.group(1)} ${goldMatch.group(2)}-${goldMatch.group(3)}';
  }
  return trimmed.isEmpty ? 'Projekt iz radnih zadataka' : trimmed;
}

String _buildTaskId({
  required String buildingId,
  required String wohnungId,
  required String taskGroup,
  required String taskType,
}) {
  final groupSlug = _slugify(taskGroup);
  final typeSlug = _slugify(taskType.isEmpty ? taskGroup : taskType);
  return '$buildingId.$wohnungId.$groupSlug.$typeSlug';
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

_ImportOptions? _parseArgs(List<String> args) {
  String? credentialsPath;
  String? inputPath;
  var outputPath = 'seed/work_tasks_import.json';
  var projectId = 'dhego-fb024';

  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    switch (arg) {
      case '--credentials':
        if (index + 1 >= args.length) {
          return null;
        }
        credentialsPath = args[++index];
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
      case '--project':
        if (index + 1 >= args.length) {
          return null;
        }
        projectId = args[++index];
      default:
        return null;
    }
  }

  if (credentialsPath == null || inputPath == null) {
    return null;
  }

  return _ImportOptions(
    credentialsPath: credentialsPath,
    inputPath: inputPath,
    outputPath: outputPath,
    projectId: projectId,
  );
}

void _printUsage() {
  stdout.writeln(
    'Usage:\n'
    '  dart run tool/work_task_import.dart '
    '--credentials <service-account.json> '
    '--input <Arbeitsablaeufe.xlsx> '
    '[--output seed/work_tasks_import.json] '
    '[--project dhego-fb024]',
  );
}

class _ImportOptions {
  const _ImportOptions({
    required this.credentialsPath,
    required this.inputPath,
    required this.outputPath,
    required this.projectId,
  });

  final String credentialsPath;
  final String inputPath;
  final String outputPath;
  final String projectId;
}

class _TaskHeader {
  const _TaskHeader({this.group = '', this.type = ''});

  final String group;
  final String type;
}

class _TaskImportResult {
  const _TaskImportResult({
    required this.projects,
    required this.buildings,
    required this.wohnungs,
    required this.tasks,
    required this.skipped,
  });

  final List<Map<String, dynamic>> projects;
  final List<Map<String, dynamic>> buildings;
  final List<Map<String, dynamic>> wohnungs;
  final List<Map<String, dynamic>> tasks;
  final List<String> skipped;
}

class _ReferenceData {
  const _ReferenceData({
    required this.projects,
    required this.buildings,
    required this.wohnungs,
  });

  final List<_ProjectRef> projects;
  final List<_BuildingRef> buildings;
  final List<_WohnungRef> wohnungs;

  _ProjectRef findOrCreateProject(String projectName) {
    final normalizedName = _normalizeKey(projectName);
    for (final project in projects) {
      if (_normalizeKey(project.name) == normalizedName ||
          _normalizeKey(project.id) == normalizedName) {
        return project;
      }
    }

    return _ProjectRef(
      id: _slugify(projectName),
      name: projectName,
      managerId: '',
      managerName: '',
      managerEmail: '',
    );
  }

  _BuildingRef findOrCreateBuilding({
    required _ProjectRef project,
    required String sheetName,
    required String titleCell,
  }) {
    final normalizedSheet = _normalizeKey(sheetName);
    final normalizedTitle = _normalizeKey(titleCell);
    final sheetSuffix = _normalizeKey(
      sheetName.replaceFirst(RegExp(r'^geb[aä]ude[_\s-]*', caseSensitive: false), ''),
    );
    final titleSuffix = _lastTokenKey(titleCell);

    for (final building in buildings) {
      final keys = <String>{
        _normalizeKey(building.name),
      };
      if (building.name.contains(' ')) {
        keys.add(_lastTokenKey(building.name));
      }
      if (keys.contains(normalizedSheet) ||
          keys.contains(normalizedTitle) ||
          (sheetSuffix.isNotEmpty && keys.contains(sheetSuffix)) ||
          (titleSuffix.isNotEmpty && keys.contains(titleSuffix))) {
        return building.withProjectName(
          projects.firstWhere(
            (project) => project.id == building.projectId,
            orElse: () => const _ProjectRef(
              id: '',
              name: '',
              managerId: '',
              managerName: '',
              managerEmail: '',
            ),
          ).name,
        );
      }
    }

    for (final building in buildings) {
      final key = _normalizeKey(building.name);
      if ((sheetSuffix.isNotEmpty && key.endsWith(sheetSuffix)) ||
          (titleSuffix.isNotEmpty && key.endsWith(titleSuffix))) {
        return building.withProjectName(
          projects.firstWhere(
            (project) => project.id == building.projectId,
            orElse: () => const _ProjectRef(
              id: '',
              name: '',
              managerId: '',
              managerName: '',
              managerEmail: '',
            ),
          ).name,
        );
      }
    }

    final displayName = _displayBuildingName(sheetName);
    return _BuildingRef(
      id: '${project.id}_${_slugify(displayName)}',
      name: displayName,
      projectId: project.id,
      projectName: project.name,
    );
  }

  _WohnungRef findOrCreateWohnung({
    required String buildingId,
    required String apartmentName,
    required String rawApartment,
  }) {
    final candidates = wohnungs.where((wohnung) => wohnung.buildingId == buildingId);
    final normalized = _normalizeKey(apartmentName);
    final numeric = _apartmentNumericKey(apartmentName);
    final rawNumeric = _apartmentNumericKey(rawApartment);

    for (final wohnung in candidates) {
      if (_normalizeKey(wohnung.name) == normalized) {
        return wohnung;
      }
    }
    for (final wohnung in candidates) {
      final candidateNumeric = _apartmentNumericKey(wohnung.name);
      if (candidateNumeric == numeric || candidateNumeric == rawNumeric) {
        return wohnung;
      }
    }
    return _WohnungRef(
      id: '${buildingId}_${_slugify(apartmentName)}',
      name: apartmentName,
      buildingId: buildingId,
      checklistType: '',
    );
  }
}

class _ProjectRef {
  const _ProjectRef({
    required this.id,
    required this.name,
    required this.managerId,
    required this.managerName,
    required this.managerEmail,
  });

  final String id;
  final String name;
  final String managerId;
  final String managerName;
  final String managerEmail;

  factory _ProjectRef.fromDocument(Map<String, dynamic> document) {
    final fields = document['fields'] as Map<String, dynamic>? ?? <String, dynamic>{};
    return _ProjectRef(
      id: _documentId(document),
      name: _fieldString(fields, 'name'),
      managerId: _fieldString(fields, 'managerId'),
      managerName: _fieldString(fields, 'managerName'),
      managerEmail: _fieldString(fields, 'managerEmail'),
    );
  }
}

class _BuildingRef {
  const _BuildingRef({
    required this.id,
    required this.name,
    required this.projectId,
    required this.projectName,
  });

  final String id;
  final String name;
  final String projectId;
  final String projectName;

  factory _BuildingRef.fromDocument(Map<String, dynamic> document) {
    final fields = document['fields'] as Map<String, dynamic>? ?? <String, dynamic>{};
    return _BuildingRef(
      id: _documentId(document),
      name: _fieldString(fields, 'name'),
      projectId: _fieldString(fields, 'projectId'),
      projectName: '',
    );
  }

  _BuildingRef withProjectName(String nextProjectName) {
    return _BuildingRef(
      id: id,
      name: name,
      projectId: projectId,
      projectName: nextProjectName,
    );
  }
}

class _WohnungRef {
  const _WohnungRef({
    required this.id,
    required this.name,
    required this.buildingId,
    required this.checklistType,
  });

  final String id;
  final String name;
  final String buildingId;
  final String checklistType;

  factory _WohnungRef.fromDocument(Map<String, dynamic> document) {
    final fields = document['fields'] as Map<String, dynamic>? ?? <String, dynamic>{};
    return _WohnungRef(
      id: _documentId(document),
      name: _fieldString(fields, 'name'),
      buildingId: _fieldString(fields, 'buildingId'),
      checklistType: _fieldString(fields, 'checklistType'),
    );
  }

  _WohnungRef withChecklistType(String nextChecklistType) {
    return _WohnungRef(
      id: id,
      name: name,
      buildingId: buildingId,
      checklistType: nextChecklistType,
    );
  }
}

String _displayBuildingName(String sheetName) {
  final stripped = sheetName
      .replaceFirst(RegExp(r'^geb[aä]ude[_\s-]*', caseSensitive: false), '')
      .trim();
  return stripped.isEmpty ? sheetName.trim() : stripped;
}

String _documentId(Map<String, dynamic> document) {
  final name = document['name']?.toString() ?? '';
  if (name.isEmpty) {
    return '';
  }
  return name.split('/').last;
}

String _fieldString(Map<String, dynamic> fields, String key) {
  final raw = fields[key] as Map<String, dynamic>?;
  if (raw == null) {
    return '';
  }
  return raw['stringValue']?.toString() ??
      raw['integerValue']?.toString() ??
      raw['doubleValue']?.toString() ??
      '';
}

String _normalizeKey(String value) {
  return value
      .toLowerCase()
      .replaceAll('\u00e4', 'a')
      .replaceAll('\u00f6', 'o')
      .replaceAll('\u00fc', 'u')
      .replaceAll('\u00df', 'ss')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

String _lastTokenKey(String value) {
  final parts = value.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty) {
    return '';
  }
  return _normalizeKey(parts.last);
}

String _apartmentNumericKey(String value) {
  final stripped = value
      .toUpperCase()
      .replaceFirst(RegExp(r'^(WE|WOHNUNG)\s*'), '')
      .replaceAll(RegExp(r'[^A-Z0-9]+'), '');
  final match = RegExp(r'^0*([0-9]+)([A-Z]*)$').firstMatch(stripped);
  if (match == null) {
    return stripped;
  }
  return '${match.group(1)}${match.group(2)}';
}
