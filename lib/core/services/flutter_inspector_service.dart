import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vm_service/utils.dart' as vm_service_utils;
import 'package:vm_service/vm_service.dart' as vm_service;
import 'package:vm_service/vm_service_io.dart';

import '../models/flora_models.dart';

class FlutterInspectorService {
  const FlutterInspectorService._();

  static const String _selectionObjectGroup = 'flora_inspector_selection_group';
  static const String _selectionModeExtension = 'ext.flutter.inspector.show';

  static Future<void> configureProjectRoots({
    required String vmServiceUrl,
    required String projectRoot,
  }) async {
    await _withConnectedInspector<void>(
      vmServiceUrl: vmServiceUrl,
      action:
          (
            vm_service.VmService service,
            String isolateId,
            Set<String> extensions,
          ) async {
            await _configureProjectRootsInternal(
              service: service,
              isolateId: isolateId,
              extensions: extensions,
              projectRoot: projectRoot,
            );
          },
    );
  }

  static Future<void> disposeGroup({
    required String vmServiceUrl,
    required String groupName,
  }) async {
    await _withConnectedInspector<void>(
      vmServiceUrl: vmServiceUrl,
      action:
          (
            vm_service.VmService service,
            String isolateId,
            Set<String> extensions,
          ) async {
            await _disposeGroupInternal(
              service: service,
              isolateId: isolateId,
              extensions: extensions,
              groupName: groupName,
            );
          },
    );
  }

  static Future<InspectorTreeSnapshot?> fetchAnnotationSnapshot({
    required String vmServiceUrl,
    required String projectRoot,
    String groupName = 'flora_annotation_tree_group',
  }) async {
    return _withConnectedInspector<InspectorTreeSnapshot?>(
      vmServiceUrl: vmServiceUrl,
      action:
          (
            vm_service.VmService service,
            String isolateId,
            Set<String> extensions,
          ) async {
            await _configureProjectRootsInternal(
              service: service,
              isolateId: isolateId,
              extensions: extensions,
              projectRoot: projectRoot,
            );
            await _disposeGroupInternal(
              service: service,
              isolateId: isolateId,
              extensions: extensions,
              groupName: groupName,
            );

            if (!await _isWidgetTreeReadyInternal(
              service: service,
              isolateId: isolateId,
              extensions: extensions,
            )) {
              return null;
            }

            final rootNode = await _fetchRootSummaryTreeInternal(
              service: service,
              isolateId: isolateId,
              extensions: extensions,
              groupName: groupName,
            );
            if (rootNode == null || rootNode.isEmpty) {
              return null;
            }

            final parsedRoot = _parseInspectorTreeNode(
              rootNode,
              ancestors: const <String>[],
              depth: 0,
            );
            final counts = _countInspectorNodes(<InspectorTreeNode>[
              parsedRoot,
            ]);

            return InspectorTreeSnapshot(
              groupName: groupName,
              capturedAt: DateTime.now(),
              rootNodes: <InspectorTreeNode>[parsedRoot],
              totalNodeCount: counts.total,
              layoutNodeCount: counts.layout,
              controlNodeCount: counts.control,
              textNodeCount: counts.text,
            );
          },
    );
  }

  static Future<InspectorNodeLayoutDetails?> fetchLayoutDetails({
    required String vmServiceUrl,
    required String valueId,
    required String groupName,
    int subtreeDepth = 1,
  }) async {
    return _withConnectedInspector<InspectorNodeLayoutDetails?>(
      vmServiceUrl: vmServiceUrl,
      action:
          (
            vm_service.VmService service,
            String isolateId,
            Set<String> extensions,
          ) async {
            if (!extensions.contains(
              'ext.flutter.inspector.getLayoutExplorerNode',
            )) {
              return null;
            }

            final response = await service.callServiceExtension(
              'ext.flutter.inspector.getLayoutExplorerNode',
              isolateId: isolateId,
              args: <String, dynamic>{
                'id': valueId,
                'subtreeDepth': '$subtreeDepth',
                'groupName': groupName,
              },
            );

            final result = _asMap(response.json?['result']);
            if (result == null || result.isEmpty) {
              return null;
            }

            final constraints = _asMap(result['constraints']);
            final size = _asMap(result['size']);
            final parentData = _asMap(result['parentData']);
            final renderObject = _asMap(result['renderObject']);
            final parentRenderElement = _asMap(result['parentRenderElement']);

            return InspectorNodeLayoutDetails(
              constraintsDescription: constraints?['description']?.toString(),
              width: _asDouble(size?['width']),
              height: _asDouble(size?['height']),
              flexFactor: _asInt(result['flexFactor']),
              flexFit: result['flexFit']?.toString(),
              offsetX: _asDouble(parentData?['offsetX']),
              offsetY: _asDouble(parentData?['offsetY']),
              textPreview:
                  result['textPreview']?.toString() ??
                  renderObject?['textPreview']?.toString(),
              renderObjectDescription: renderObject?['description']?.toString(),
              parentRenderElementDescription:
                  parentRenderElement?['description']?.toString(),
            );
          },
    );
  }

  static Future<Uint8List?> screenshotNode({
    required String vmServiceUrl,
    required String valueId,
    double width = 280,
    double height = 180,
    double margin = 12,
    double maxPixelRatio = 1.5,
  }) async {
    return _withConnectedInspector<Uint8List?>(
      vmServiceUrl: vmServiceUrl,
      action:
          (
            vm_service.VmService service,
            String isolateId,
            Set<String> extensions,
          ) async {
            if (!extensions.contains('ext.flutter.inspector.screenshot')) {
              return null;
            }

            final response = await service.callServiceExtension(
              'ext.flutter.inspector.screenshot',
              isolateId: isolateId,
              args: <String, dynamic>{
                'id': valueId,
                'width': width.toString(),
                'height': height.toString(),
                'margin': margin.toString(),
                'maxPixelRatio': maxPixelRatio.toString(),
                'debugPaint': 'false',
              },
            );

            final encoded = response.json?['result']?.toString();
            if (encoded == null || encoded.isEmpty) {
              return null;
            }
            return base64Decode(encoded);
          },
    );
  }

  static Future<bool> setSelectionById({
    required String vmServiceUrl,
    required String valueId,
    required String groupName,
  }) async {
    final result = await _withConnectedInspector<bool>(
      vmServiceUrl: vmServiceUrl,
      action:
          (
            vm_service.VmService service,
            String isolateId,
            Set<String> extensions,
          ) async {
            if (!extensions.contains(
              'ext.flutter.inspector.setSelectionById',
            )) {
              return false;
            }

            final response = await service.callServiceExtension(
              'ext.flutter.inspector.setSelectionById',
              isolateId: isolateId,
              args: <String, dynamic>{'arg': valueId, 'objectGroup': groupName},
            );
            final raw = response.json?['result'];
            if (raw is bool) {
              return raw;
            }
            return raw?.toString() == 'true';
          },
    );

    return result ?? false;
  }

  static Future<InspectorSelectionContext?> fetchSelectedSummaryWidget({
    required String vmServiceUrl,
  }) async {
    vm_service.VmService? service;
    String? isolateId;

    try {
      final uri = Uri.tryParse(vmServiceUrl);
      if (uri == null) {
        return null;
      }

      final wsUri = vm_service_utils.convertToWebSocketUrl(
        serviceProtocolUrl: uri,
      );
      service = await vmServiceConnectUri(wsUri.toString());

      final vm = await service.getVM();
      isolateId = _pickIsolateId(vm);
      if (isolateId == null) {
        return null;
      }

      final isolate = await service.getIsolate(isolateId);
      final extensions = isolate.extensionRPCs ?? const <String>[];
      if (!extensions.contains(
        'ext.flutter.inspector.getSelectedSummaryWidget',
      )) {
        return null;
      }

      final selectedResponse = await service.callServiceExtension(
        'ext.flutter.inspector.getSelectedSummaryWidget',
        isolateId: isolateId,
        args: <String, dynamic>{'objectGroup': _selectionObjectGroup},
      );

      final selectedNode = _asMap(selectedResponse.json?['result']);
      if (selectedNode == null || selectedNode.isEmpty) {
        return null;
      }

      final rawDescription =
          selectedNode['description']?.toString() ?? 'Unknown widget';
      final widgetName = _extractWidgetName(rawDescription);
      final valueId = selectedNode['valueId']?.toString();

      final creationLocation = _asMap(selectedNode['creationLocation']);
      final sourceFile = _normalizeSourcePath(
        creationLocation?['file']?.toString(),
      );
      final line = _asInt(creationLocation?['line']);
      final endLine = _estimateWidgetEndLine(
        sourceFile: sourceFile,
        startLine: line,
      );
      final column = _asInt(creationLocation?['column']);

      final ancestors = await _fetchAncestorPath(
        service: service,
        isolateId: isolateId,
        valueId: valueId,
      );

      return InspectorSelectionContext(
        valueId: valueId,
        widgetName: widgetName,
        description: rawDescription,
        sourceFile: sourceFile,
        line: line,
        endLine: endLine,
        column: column,
        ancestorPath: ancestors,
        capturedAt: DateTime.now(),
      );
    } on vm_service.RPCError {
      return null;
    } catch (_) {
      return null;
    } finally {
      if (service != null) {
        if (isolateId != null) {
          try {
            await service.callServiceExtension(
              'ext.flutter.inspector.disposeGroup',
              isolateId: isolateId,
              args: <String, dynamic>{'objectGroup': _selectionObjectGroup},
            );
          } catch (_) {
            // Ignore disposeGroup failures.
          }
        }

        try {
          await service.dispose();
        } catch (_) {
          // Ignore close failures.
        }
      }
    }
  }

  static Future<bool> setInspectorSelectionMode({
    required String vmServiceUrl,
    required bool enabled,
  }) async {
    final result = await _withConnectedInspector(
      vmServiceUrl: vmServiceUrl,
      action:
          (
            vm_service.VmService service,
            String isolateId,
            Set<String> extensions,
          ) async {
            if (!extensions.contains(_selectionModeExtension)) {
              return false;
            }

            await service.callServiceExtension(
              _selectionModeExtension,
              isolateId: isolateId,
              args: <String, dynamic>{'enabled': enabled ? 'true' : 'false'},
            );
            return true;
          },
    );

    return result ?? false;
  }

  static Future<void> _configureProjectRootsInternal({
    required vm_service.VmService service,
    required String isolateId,
    required Set<String> extensions,
    required String projectRoot,
  }) async {
    final projectUri = Uri.directory(projectRoot).toString();
    if (extensions.contains('ext.flutter.inspector.setPubRootDirectories')) {
      await service.callServiceExtension(
        'ext.flutter.inspector.setPubRootDirectories',
        isolateId: isolateId,
        args: <String, dynamic>{'arg0': projectUri},
      );
      return;
    }

    if (extensions.contains('ext.flutter.inspector.addPubRootDirectories')) {
      await service.callServiceExtension(
        'ext.flutter.inspector.addPubRootDirectories',
        isolateId: isolateId,
        args: <String, dynamic>{'arg0': projectUri},
      );
    }
  }

  static Future<void> _disposeGroupInternal({
    required vm_service.VmService service,
    required String isolateId,
    required Set<String> extensions,
    required String groupName,
  }) async {
    if (!extensions.contains('ext.flutter.inspector.disposeGroup')) {
      return;
    }

    try {
      await service.callServiceExtension(
        'ext.flutter.inspector.disposeGroup',
        isolateId: isolateId,
        args: <String, dynamic>{'objectGroup': groupName},
      );
    } catch (_) {
      // Ignore stale-group disposal failures.
    }
  }

  static Future<bool> _isWidgetTreeReadyInternal({
    required vm_service.VmService service,
    required String isolateId,
    required Set<String> extensions,
  }) async {
    if (!extensions.contains('ext.flutter.inspector.isWidgetTreeReady')) {
      return true;
    }

    try {
      final response = await service.callServiceExtension(
        'ext.flutter.inspector.isWidgetTreeReady',
        isolateId: isolateId,
      );
      final result = response.json?['result'];
      if (result is bool) {
        return result;
      }
      return result?.toString() != 'false';
    } catch (_) {
      return true;
    }
  }

  static Future<Map<String, dynamic>?> _fetchRootSummaryTreeInternal({
    required vm_service.VmService service,
    required String isolateId,
    required Set<String> extensions,
    required String groupName,
  }) async {
    if (extensions.contains(
      'ext.flutter.inspector.getRootWidgetSummaryTreeWithPreviews',
    )) {
      final response = await service.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetSummaryTreeWithPreviews',
        isolateId: isolateId,
        args: <String, dynamic>{'groupName': groupName},
      );
      return _asMap(response.json?['result']);
    }

    if (extensions.contains('ext.flutter.inspector.getRootWidgetTree')) {
      final response = await service.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetTree',
        isolateId: isolateId,
        args: <String, dynamic>{
          'groupName': groupName,
          'isSummaryTree': 'true',
          'withPreviews': 'true',
        },
      );
      return _asMap(response.json?['result']);
    }

    if (extensions.contains('ext.flutter.inspector.getRootWidgetSummaryTree')) {
      final response = await service.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetSummaryTree',
        isolateId: isolateId,
        args: <String, dynamic>{'objectGroup': groupName},
      );
      return _asMap(response.json?['result']);
    }

    return null;
  }

  static Future<T?> _withConnectedInspector<T>({
    required String vmServiceUrl,
    required Future<T> Function(
      vm_service.VmService service,
      String isolateId,
      Set<String> extensions,
    )
    action,
  }) async {
    vm_service.VmService? service;
    try {
      final uri = Uri.tryParse(vmServiceUrl);
      if (uri == null) {
        return null;
      }

      final wsUri = vm_service_utils.convertToWebSocketUrl(
        serviceProtocolUrl: uri,
      );
      service = await vmServiceConnectUri(wsUri.toString());

      final vm = await service.getVM();
      final isolateId = _pickIsolateId(vm);
      if (isolateId == null) {
        return null;
      }

      final isolate = await service.getIsolate(isolateId);
      final extensions = Set<String>.from(
        isolate.extensionRPCs ?? const <String>[],
      );
      return action(service, isolateId, extensions);
    } on vm_service.RPCError {
      return null;
    } catch (_) {
      return null;
    } finally {
      if (service != null) {
        try {
          await service.dispose();
        } catch (_) {
          // Ignore close failures.
        }
      }
    }
  }

  static int? _estimateWidgetEndLine({
    required String? sourceFile,
    required int? startLine,
  }) {
    if (sourceFile == null || startLine == null || startLine < 1) {
      return null;
    }

    try {
      final file = File(sourceFile);
      if (!file.existsSync()) {
        return null;
      }

      final lines = file.readAsLinesSync();
      if (startLine > lines.length) {
        return null;
      }

      final snippet = lines.sublist(startLine - 1).join('\n');
      final openParenIndex = _findOpenParen(snippet);
      if (openParenIndex < 0) {
        return startLine;
      }

      final closeParenIndex = _findMatchingParen(snippet, openParenIndex);
      if (closeParenIndex < 0) {
        return startLine;
      }

      final lineDelta = '\n'
          .allMatches(snippet.substring(0, closeParenIndex + 1))
          .length;
      return startLine + lineDelta;
    } catch (_) {
      return startLine;
    }
  }

  static InspectorTreeNode _parseInspectorTreeNode(
    Map<String, dynamic> rawNode, {
    required List<String> ancestors,
    required int depth,
  }) {
    final description =
        rawNode['description']?.toString() ??
        rawNode['name']?.toString() ??
        'Unknown widget';
    final widgetName = _extractWidgetName(description);
    final creationLocation = _asMap(rawNode['creationLocation']);
    final sourceFile = _normalizeSourcePath(
      creationLocation?['file']?.toString(),
    );
    final line = _asInt(creationLocation?['line']);
    final endLine = _estimateWidgetEndLine(
      sourceFile: sourceFile,
      startLine: line,
    );
    final column = _asInt(creationLocation?['column']);
    final textPreview = rawNode['textPreview']?.toString();
    final createdByLocalProject = rawNode['createdByLocalProject'] == true;
    final stableKey = _buildStableNodeKey(
      widgetName: widgetName,
      sourceFile: sourceFile,
      line: line,
      column: column,
      ancestors: ancestors,
      description: description,
    );

    final childAncestors = <String>[...ancestors, widgetName];
    final children = <InspectorTreeNode>[];
    final rawChildren = rawNode['children'];
    if (rawChildren is List) {
      for (final child in rawChildren) {
        final childMap = _asMap(child);
        if (childMap == null || childMap.isEmpty) {
          continue;
        }
        children.add(
          _parseInspectorTreeNode(
            childMap,
            ancestors: childAncestors,
            depth: depth + 1,
          ),
        );
      }
    }

    return InspectorTreeNode(
      valueId: rawNode['valueId']?.toString(),
      stableKey: stableKey,
      widgetName: widgetName,
      description: description,
      textPreview: textPreview,
      sourceFile: sourceFile,
      line: line,
      endLine: endLine,
      column: column,
      createdByLocalProject: createdByLocalProject,
      ancestorPath: ancestors,
      depth: depth,
      children: List<InspectorTreeNode>.unmodifiable(children),
    );
  }

  static String _buildStableNodeKey({
    required String widgetName,
    required String? sourceFile,
    required int? line,
    required int? column,
    required List<String> ancestors,
    required String description,
  }) {
    final ancestry = ancestors.join('>');
    final location = '${sourceFile ?? 'unknown'}:${line ?? -1}:${column ?? -1}';
    return '$widgetName|$location|$ancestry|$description';
  }

  static _InspectorTreeCounts _countInspectorNodes(
    List<InspectorTreeNode> nodes,
  ) {
    var total = 0;
    var layout = 0;
    var control = 0;
    var text = 0;

    void walk(InspectorTreeNode node) {
      total += 1;
      final normalized = node.widgetName.toLowerCase();
      if (_looksLikeLayoutWidget(normalized)) {
        layout += 1;
      }
      if (_looksLikeControlWidget(normalized)) {
        control += 1;
      }
      if (_looksLikeTextWidget(normalized)) {
        text += 1;
      }
      for (final child in node.children) {
        walk(child);
      }
    }

    for (final node in nodes) {
      walk(node);
    }

    return _InspectorTreeCounts(
      total: total,
      layout: layout,
      control: control,
      text: text,
    );
  }

  static bool _looksLikeLayoutWidget(String widgetName) {
    const layoutFragments = <String>{
      'scaffold',
      'container',
      'column',
      'row',
      'stack',
      'padding',
      'align',
      'center',
      'sizedbox',
      'flex',
      'expanded',
      'flexible',
      'wrap',
      'listview',
      'gridview',
      'scrollview',
      'sliver',
      'positioned',
      'safearea',
      'appbar',
      'card',
      'decoratedbox',
      'coloredbox',
      'clip',
      'constrainedbox',
      'fractionallysizedbox',
      'aspectratio',
      'layoutbuilder',
      'placeholder',
      'intrinsic',
    };
    return layoutFragments.any(widgetName.contains);
  }

  static bool _looksLikeControlWidget(String widgetName) {
    const controlFragments = <String>{
      'button',
      'textfield',
      'textformfield',
      'switch',
      'checkbox',
      'radio',
      'slider',
      'dropdown',
      'popupmenu',
      'gesture',
      'inkwell',
      'listtile',
      'tabbar',
      'segmentedbutton',
      'floatingactionbutton',
      'iconbutton',
    };
    return controlFragments.any(widgetName.contains);
  }

  static bool _looksLikeTextWidget(String widgetName) {
    const textFragments = <String>{
      'text',
      'richtext',
      'selectabletext',
      'editabletext',
    };
    return textFragments.any(widgetName.contains);
  }

  static int _findOpenParen(String text) {
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var inLineComment = false;
    var inBlockComment = false;
    var escaped = false;

    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      final next = i + 1 < text.length ? text[i + 1] : '';

      if (inLineComment) {
        if (char == '\n') {
          inLineComment = false;
        }
        continue;
      }

      if (inBlockComment) {
        if (char == '*' && next == '/') {
          inBlockComment = false;
          i++;
        }
        continue;
      }

      if (inSingleQuote) {
        if (!escaped && char == "'") {
          inSingleQuote = false;
        }
        escaped = !escaped && char == '\\';
        continue;
      }

      if (inDoubleQuote) {
        if (!escaped && char == '"') {
          inDoubleQuote = false;
        }
        escaped = !escaped && char == '\\';
        continue;
      }

      if (char == '/' && next == '/') {
        inLineComment = true;
        i++;
        continue;
      }

      if (char == '/' && next == '*') {
        inBlockComment = true;
        i++;
        continue;
      }

      if (char == "'") {
        inSingleQuote = true;
        escaped = false;
        continue;
      }

      if (char == '"') {
        inDoubleQuote = true;
        escaped = false;
        continue;
      }

      if (char == '(') {
        return i;
      }
    }

    return -1;
  }

  static int _findMatchingParen(String text, int openParenIndex) {
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var inLineComment = false;
    var inBlockComment = false;
    var escaped = false;
    var depth = 0;

    for (var i = openParenIndex; i < text.length; i++) {
      final char = text[i];
      final next = i + 1 < text.length ? text[i + 1] : '';

      if (inLineComment) {
        if (char == '\n') {
          inLineComment = false;
        }
        continue;
      }

      if (inBlockComment) {
        if (char == '*' && next == '/') {
          inBlockComment = false;
          i++;
        }
        continue;
      }

      if (inSingleQuote) {
        if (!escaped && char == "'") {
          inSingleQuote = false;
        }
        escaped = !escaped && char == '\\';
        continue;
      }

      if (inDoubleQuote) {
        if (!escaped && char == '"') {
          inDoubleQuote = false;
        }
        escaped = !escaped && char == '\\';
        continue;
      }

      if (char == '/' && next == '/') {
        inLineComment = true;
        i++;
        continue;
      }

      if (char == '/' && next == '*') {
        inBlockComment = true;
        i++;
        continue;
      }

      if (char == "'") {
        inSingleQuote = true;
        escaped = false;
        continue;
      }

      if (char == '"') {
        inDoubleQuote = true;
        escaped = false;
        continue;
      }

      if (char == '(') {
        depth++;
        continue;
      }

      if (char == ')') {
        depth--;
        if (depth == 0) {
          return i;
        }
      }
    }

    return -1;
  }

  static Future<List<String>> _fetchAncestorPath({
    required vm_service.VmService service,
    required String isolateId,
    required String? valueId,
  }) async {
    if (valueId == null || valueId.isEmpty) {
      return const <String>[];
    }

    try {
      final chainResponse = await service.callServiceExtension(
        'ext.flutter.inspector.getParentChain',
        isolateId: isolateId,
        args: <String, dynamic>{
          'objectGroup': _selectionObjectGroup,
          'arg': valueId,
        },
      );

      final rawChain = chainResponse.json?['result'];
      if (rawChain is! List) {
        return const <String>[];
      }

      final ancestors = <String>[];
      for (final entry in rawChain) {
        final node = _asMap(_asMap(entry)?['node']);
        final description = node?['description']?.toString();
        if (description == null || description.trim().isEmpty) {
          continue;
        }
        ancestors.add(_extractWidgetName(description));
      }
      return ancestors;
    } on vm_service.RPCError {
      return const <String>[];
    }
  }

  static String? _pickIsolateId(vm_service.VM vm) {
    for (final isolate in vm.isolates ?? const <vm_service.IsolateRef>[]) {
      final id = isolate.id;
      if (id != null && id.isNotEmpty) {
        return id;
      }
    }
    return null;
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    return null;
  }

  static int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  static double? _asDouble(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is int) {
      return value.toDouble();
    }
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  static String _extractWidgetName(String description) {
    final trimmed = description.trim();
    if (trimmed.isEmpty) {
      return 'UnknownWidget';
    }

    final match = RegExp(r'^[A-Za-z0-9_<>]+').firstMatch(trimmed);
    return (match?.group(0) ?? trimmed).trim();
  }

  static String? _normalizeSourcePath(String? rawPath) {
    if (rawPath == null || rawPath.trim().isEmpty) {
      return null;
    }

    final trimmed = rawPath.trim();
    if (trimmed.startsWith('file://')) {
      try {
        return Uri.parse(trimmed).toFilePath(windows: Platform.isWindows);
      } catch (_) {
        return trimmed;
      }
    }

    return trimmed;
  }
}

class _InspectorTreeCounts {
  const _InspectorTreeCounts({
    required this.total,
    required this.layout,
    required this.control,
    required this.text,
  });

  final int total;
  final int layout;
  final int control;
  final int text;
}
