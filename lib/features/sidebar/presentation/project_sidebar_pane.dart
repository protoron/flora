import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:webview_windows/webview_windows.dart';

import '../../../app/theme/flora_theme.dart';
import '../../../core/models/flora_models.dart';
import '../../../core/services/flutter_inspector_service.dart';
import '../../../core/state/flora_providers.dart';

const _annotationPromptTemplates = <PromptTemplate>[
  PromptTemplate(
    title: 'Polish',
    summary: 'Tighten spacing, hierarchy, and responsiveness for the target.',
    commandHint:
        'Polish the selected UI target. Improve spacing, alignment, typography, and responsive behavior without changing the underlying feature flow.',
  ),
  PromptTemplate(
    title: 'Layout',
    summary: 'Adjust structure and sizing around the target widget.',
    commandHint:
        'Refine the layout around the selected UI target. Focus on sizing, padding, alignment, and edge cases across narrow and wide desktop widths.',
  ),
  PromptTemplate(
    title: 'Accessibility',
    summary: 'Improve clarity, hit areas, and accessibility cues.',
    commandHint:
        'Improve the selected UI target for accessibility and interaction quality. Review contrast, hit targets, focus affordances, semantics, and state feedback.',
  ),
];

enum _AnnotationNodeFilter { layout, controls, text, all }

extension on _AnnotationNodeFilter {
  String get label {
    switch (this) {
      case _AnnotationNodeFilter.layout:
        return 'Layout';
      case _AnnotationNodeFilter.controls:
        return 'Controls';
      case _AnnotationNodeFilter.text:
        return 'Text';
      case _AnnotationNodeFilter.all:
        return 'All';
    }
  }
}

class ProjectSidebarPane extends ConsumerStatefulWidget {
  const ProjectSidebarPane({super.key});

  @override
  ConsumerState<ProjectSidebarPane> createState() => _ProjectSidebarPaneState();
}

class _ProjectSidebarPaneState extends ConsumerState<ProjectSidebarPane> {
  static const String _annotationTreeGroupName = 'flora_annotation_tree_group';

  final WebviewController _appWebview = WebviewController();
  final WebviewController _devToolsWebview = WebviewController();
  final FocusNode _previewFocusNode = FocusNode(
    debugLabel: 'preview-pane-shortcuts',
  );

  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _runCommandCtrl = TextEditingController(
    text: 'flutter run -d web-server --web-hostname 127.0.0.1',
  );
  final TextEditingController _annotationSearchCtrl = TextEditingController();

  Process? _flutterProcess;
  Process? _devToolsProcess;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  StreamSubscription<String>? _devToolsStdoutSub;
  StreamSubscription<String>? _devToolsStderrSub;
  Timer? _hotReloadDebounceTimer;
  Timer? _annotationRefreshTimer;

  bool _appWebviewInitialized = false;
  bool _devToolsWebviewInitialized = false;
  bool _loadingPreview = false;
  bool _loadingDevTools = false;
  bool _runningFlutter = false;
  String? _error;
  String _status = 'Idle';
  final List<String> _logs = <String>[];

  String? _appUrl;
  String? _vmServiceUrl;
  String? _devToolsUrl;
  _PreviewTab _activeTab = _PreviewTab.app;
  _PreviewBuildType _selectedBuildType = _PreviewBuildType.web;
  String? _lastProjectRoot;
  bool _showSettings = false;
  bool _ctrlToggleArmed = false;
  bool _interactionModeBusy = false;
  bool _inspectorDefaultsApplied = false;
  bool _loadingAnnotationSnapshot = false;
  bool _loadingSelectionDetails = false;
  InspectorTreeSnapshot? _annotationSnapshot;
  InspectorNodeLayoutDetails? _selectedLayoutDetails;
  Uint8List? _selectedScreenshotBytes;
  String? _selectedAnnotationStableKey;
  _AnnotationNodeFilter _annotationFilter = _AnnotationNodeFilter.layout;
  int _annotationRefreshRequestId = 0;

  @override
  void initState() {
    super.initState();
    _lastProjectRoot = ref.read(projectRootProvider);
    _runCommandCtrl.text = _runCommandForBuildType(_selectedBuildType);
  }

  @override
  void dispose() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _devToolsStdoutSub?.cancel();
    _devToolsStderrSub?.cancel();

    _flutterProcess?.kill();
    _devToolsProcess?.kill();
    _hotReloadDebounceTimer?.cancel();
    _annotationRefreshTimer?.cancel();

    if (_appWebviewInitialized) {
      _appWebview.dispose();
    }
    if (_devToolsWebviewInitialized) {
      _devToolsWebview.dispose();
    }

    _urlCtrl.dispose();
    _runCommandCtrl.dispose();
    _annotationSearchCtrl.dispose();
    _previewFocusNode.dispose();
    super.dispose();
  }

  void _clearInspectorContext() {
    ref.read(inspectorSelectionProvider.notifier).state = null;
    ref.read(inspectorSelectionHistoryProvider.notifier).state = const [];
    _selectedAnnotationStableKey = null;
    _selectedLayoutDetails = null;
    _selectedScreenshotBytes = null;
  }

  Future<void> _loadApp(String url) async {
    if (url.trim().isEmpty) {
      return;
    }

    setState(() {
      _error = null;
      _loadingPreview = true;
      _status = 'Loading app preview...';
    });

    try {
      if (!_appWebviewInitialized) {
        await _appWebview.initialize();
        _appWebviewInitialized = true;
      }

      await _appWebview.loadUrl(url);
      _appUrl = url;

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'App preview connected';
      });
      _requestPreviewFocus();
      unawaited(_applyInspectorDefaults());
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _status = 'Preview failed to load';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingPreview = false;
        });
      }
    }
  }

  Future<void> _loadDevTools(String url) async {
    if (url.trim().isEmpty) {
      return;
    }

    setState(() {
      _error = null;
      _loadingDevTools = true;
      _status = 'Loading DevTools...';
    });

    try {
      if (!_devToolsWebviewInitialized) {
        await _devToolsWebview.initialize();
        _devToolsWebviewInitialized = true;
      }

      await _devToolsWebview.loadUrl(url);
      _devToolsUrl = url;
      ref.read(devToolsUrlProvider.notifier).state = url;

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'DevTools connected';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _status = 'DevTools failed to load';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingDevTools = false;
        });
      }
    }
  }

  Future<void> _runAndLoadPreview() async {
    final root = ref.read(projectRootProvider);
    if (root == null || root.trim().isEmpty) {
      setState(() {
        _error = 'Choose a project folder first.';
        _status = 'Missing project root';
      });
      return;
    }

    if (_runningFlutter) {
      return;
    }

    setState(() {
      _error = null;
      _runningFlutter = true;
      _status = 'Starting ${_selectedBuildType.label} run...';
      _appUrl = null;
      _vmServiceUrl = null;
      _devToolsUrl = null;
      _inspectorDefaultsApplied = false;
      _ctrlToggleArmed = false;
      _interactionModeBusy = false;
      _loadingAnnotationSnapshot = false;
      _loadingSelectionDetails = false;
      _annotationSnapshot = null;
      _selectedLayoutDetails = null;
      _selectedScreenshotBytes = null;
      _selectedAnnotationStableKey = null;
      _annotationFilter = _AnnotationNodeFilter.layout;
      _activeTab = _PreviewTab.app;
      _logs
        ..clear()
        ..add(_runCommandCtrl.text);
    });
    _annotationSearchCtrl.clear();
    ref.read(previewInteractionModeProvider.notifier).state =
        PreviewInteractionMode.use;

    try {
      final parts = _runCommandCtrl.text.trim().split(RegExp(r'\s+'));
      final executable = parts.isNotEmpty ? parts.first : 'flutter';
      final rawArgs = parts.length > 1 ? parts.sublist(1) : <String>[];
      final args = await _prepareRunArgs(executable, rawArgs);

      if (!mounted) {
        return;
      }

      setState(() {
        _logs
          ..clear()
          ..add('$executable ${args.join(' ')}');
      });

      final process = await Process.start(
        executable,
        args,
        workingDirectory: root,
        runInShell: true,
      );
      _flutterProcess = process;

      _stdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleFlutterLine);
      _stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleFlutterLine);

      unawaited(
        process.exitCode.then((exitCode) {
          if (!mounted) {
            return;
          }
          setState(() {
            _runningFlutter = false;
            _status = 'flutter run exited with code $exitCode';
          });
          _vmServiceUrl = null;
          _stopInspectorSync();
        }),
      );
    } on ProcessException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _runningFlutter = false;
        _error = error.message;
        _status = 'Failed to start flutter run';
      });
    }
  }

  String _runCommandForBuildType(_PreviewBuildType buildType) {
    switch (buildType) {
      case _PreviewBuildType.web:
        return 'flutter run -d web-server --web-hostname 127.0.0.1';
      case _PreviewBuildType.app:
        return 'flutter run -d windows';
      case _PreviewBuildType.mobile:
        return 'flutter run -d android';
    }
  }

  void _setBuildType(_PreviewBuildType buildType) {
    if (_selectedBuildType == buildType) {
      return;
    }

    setState(() {
      _selectedBuildType = buildType;
      _runCommandCtrl.text = _runCommandForBuildType(buildType);
      _status = 'Build type set to ${buildType.label}';
    });
  }

  void _handleProjectRootChanged(String? nextRoot) {
    if (_lastProjectRoot == nextRoot) {
      return;
    }

    _lastProjectRoot = nextRoot;
    _annotationSearchCtrl.clear();
    ref.read(previewInteractionModeProvider.notifier).state =
        PreviewInteractionMode.use;
    _clearInspectorContext();
    setState(() {
      _annotationSnapshot = null;
      _selectedLayoutDetails = null;
      _selectedScreenshotBytes = null;
      _selectedAnnotationStableKey = null;
      _annotationFilter = _AnnotationNodeFilter.layout;
    });
    _setBuildType(_PreviewBuildType.web);
    if (_runningFlutter) {
      unawaited(_stopFlutterRun());
    }
  }

  Future<List<String>> _prepareRunArgs(
    String executable,
    List<String> rawArgs,
  ) async {
    final args = List<String>.from(rawArgs);
    if (!_looksLikeFlutterExecutable(executable) || !_targetsWebServer(args)) {
      return args;
    }

    _removeFlagWithOptionalValue(args, '--web-port');

    if (!_hasFlag(args, '--web-hostname')) {
      args.addAll(<String>['--web-hostname', '127.0.0.1']);
    }

    final selectedPort = await _pickAvailablePort();
    args.addAll(<String>['--web-port', '$selectedPort']);
    _status = 'Selected free preview port $selectedPort';
    return args;
  }

  bool _looksLikeFlutterExecutable(String executable) {
    final lower = executable.toLowerCase();
    return lower == 'flutter' ||
        lower.endsWith(r'\flutter.bat') ||
        lower.endsWith('/flutter') ||
        lower.endsWith('/flutter.bat');
  }

  bool _targetsWebServer(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if ((arg == '-d' || arg == '--device-id') && i + 1 < args.length) {
        if (args[i + 1].trim().toLowerCase() == 'web-server') {
          return true;
        }
      }
      if (arg.toLowerCase().startsWith('--device-id=')) {
        final value = arg.split('=').skip(1).join('=').trim().toLowerCase();
        if (value == 'web-server') {
          return true;
        }
      }
    }
    return false;
  }

  bool _hasFlag(List<String> args, String flag) {
    for (final arg in args) {
      if (arg == flag || arg.startsWith('$flag=')) {
        return true;
      }
    }
    return false;
  }

  void _removeFlagWithOptionalValue(List<String> args, String flag) {
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == flag) {
        args.removeAt(i);
        if (i < args.length && !args[i].startsWith('-')) {
          args.removeAt(i);
        }
        return;
      }
      if (arg.startsWith('$flag=')) {
        args.removeAt(i);
        return;
      }
    }
  }

  Future<int> _pickAvailablePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  void _handleFlutterLine(String rawLine) {
    final line = rawLine.trimRight();
    if (line.isEmpty || !mounted) {
      return;
    }

    setState(() {
      _logs.add(line);
      if (_logs.length > 12) {
        _logs.removeRange(0, _logs.length - 12);
      }
    });

    final urlMatch = RegExp(r'https?://\S+').firstMatch(line);
    final url = urlMatch?.group(0);
    final lower = line.toLowerCase();
    final isDevToolsLine = _looksLikeDevToolsLine(lower, line, url);

    if (lower.contains('vm service') && url != null) {
      final detectedVmServiceUrl = _normalizeDetectedUrl(url);
      if (detectedVmServiceUrl != null) {
        final changedSession = _vmServiceUrl != detectedVmServiceUrl;
        _vmServiceUrl = detectedVmServiceUrl;
        if (changedSession) {
          _inspectorDefaultsApplied = false;
          ref.read(previewInteractionModeProvider.notifier).state =
              PreviewInteractionMode.use;
          _ctrlToggleArmed = false;
        }
        _status = 'VM service detected. Preparing Flora screen map...';
        unawaited(_applyInspectorDefaults());
      }
    }

    // DevTools links often include localhost URLs too. Handle those first so
    // they are never mistaken for the actual app preview URL.
    if (url != null && isDevToolsLine) {
      final candidate = _normalizeDetectedUrl(url);
      if (candidate != null) {
        _status = 'DevTools URL detected. Loading inspector...';
        unawaited(_loadDevTools(candidate));
      }
      return;
    }

    if (url != null && _looksLikeAppPreviewLine(lower, line)) {
      final candidate = _normalizeDetectedUrl(url);
      if (candidate != null && candidate != _appUrl) {
        _status = 'App URL detected. Loading embedded preview...';
        unawaited(_loadApp(candidate));
        return;
      }
    }

    if (lower.contains('to hot restart changes') ||
        lower.contains('flutter run key commands')) {
      setState(() {
        _status = 'Flutter app running';
      });
    }
  }

  String? _normalizeDetectedUrl(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[),;]+$'), '');
    return cleaned.startsWith('http://') || cleaned.startsWith('https://')
        ? cleaned
        : null;
  }

  bool _looksLikeAppPreviewLine(String lower, String raw) {
    return !lower.contains('devtools') &&
        !raw.contains('?uri=') &&
        (lower.contains('is being served at') ||
            lower.contains('serving at') ||
            lower.contains('local:') ||
            lower.contains('application available at'));
  }

  bool _looksLikeDevToolsLine(String lower, String raw, String? url) {
    return lower.contains('devtools') ||
        lower.contains('debugger and profiler') ||
        raw.contains('?uri=') ||
        (url?.contains('?uri=') ?? false);
  }

  Future<void> _ensureDevToolsRunning(String vmServiceUrl) async {
    if (_devToolsProcess != null) {
      return;
    }

    try {
      final process = await Process.start('dart', <String>[
        'devtools',
        '--machine',
        '--vm-uri',
        vmServiceUrl,
      ], runInShell: true);
      _devToolsProcess = process;

      _devToolsStdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleDevToolsLine);
      _devToolsStderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleDevToolsLine);

      unawaited(
        process.exitCode.then((_) {
          _devToolsProcess = null;
        }),
      );
    } catch (_) {
      // Fall back to manual URL entry if launching devtools fails.
    }
  }

  void _openDevToolsTab() {
    setState(() {
      _activeTab = _PreviewTab.devTools;
      _status = 'Opening DevTools...';
    });

    if (_vmServiceUrl != null && _devToolsProcess == null) {
      unawaited(_ensureDevToolsRunning(_vmServiceUrl!));
    }
  }

  void _handleDevToolsLine(String rawLine) {
    final line = rawLine.trim();
    if (line.isEmpty || !mounted) {
      return;
    }

    setState(() {
      _logs.add('[devtools] $line');
      if (_logs.length > 12) {
        _logs.removeRange(0, _logs.length - 12);
      }
    });

    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) {
        final params = decoded['params'];
        if (params is Map<String, dynamic>) {
          final uri = params['devToolsUri'] as String?;
          if (uri != null) {
            _urlCtrl.text = uri;
            unawaited(_loadDevTools(uri));
            return;
          }
        }
      }
    } catch (_) {
      // Not JSON output.
    }

    final url = RegExp(r'https?://\S+').firstMatch(line)?.group(0);
    if (url != null && url.contains('?uri=')) {
      final normalized = _normalizeDetectedUrl(url);
      if (normalized != null) {
        _urlCtrl.text = normalized;
        unawaited(_loadDevTools(normalized));
      }
    }
  }

  Future<void> _sendFlutterCommand(String command) async {
    final process = _flutterProcess;
    if (process == null) {
      return;
    }

    process.stdin.writeln(command);
    setState(() {
      _status = 'Sent "$command" to flutter run';
    });
  }

  void _requestPreviewFocus() {
    if (!_previewFocusNode.hasFocus) {
      _previewFocusNode.requestFocus();
    }
  }

  Future<void> _applyInspectorDefaults() async {
    final vmServiceUrl = _vmServiceUrl;
    if (vmServiceUrl == null || _inspectorDefaultsApplied) {
      return;
    }

    final projectRoot = ref.read(projectRootProvider);
    if (projectRoot != null && projectRoot.trim().isNotEmpty) {
      await FlutterInspectorService.configureProjectRoots(
        vmServiceUrl: vmServiceUrl,
        projectRoot: projectRoot,
      );
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _inspectorDefaultsApplied = true;
      _interactionModeBusy = false;
      _status =
          'Preview ready. Switch to Annotate UI to browse Flora\'s screen map.';
    });

    if (ref.read(previewInteractionModeProvider) ==
        PreviewInteractionMode.annotate) {
      unawaited(
        _refreshAnnotationSnapshot(
          preserveSelection: true,
          statusOverride: 'Refreshing the current screen map...',
        ),
      );
    }
    _requestPreviewFocus();
  }

  Future<void> _setPreviewInteractionMode(PreviewInteractionMode mode) async {
    final currentMode = ref.read(previewInteractionModeProvider);
    if (_interactionModeBusy || currentMode == mode) {
      return;
    }

    final vmServiceUrl = _vmServiceUrl;
    ref.read(previewInteractionModeProvider.notifier).state = mode;

    if (!_runningFlutter || vmServiceUrl == null) {
      setState(() {
        _status = mode == PreviewInteractionMode.annotate
            ? 'Annotate UI will open once the preview is connected.'
            : 'Use App mode ready.';
      });
      return;
    }

    setState(() {
      _interactionModeBusy = true;
      _activeTab = _PreviewTab.app;
      _status = mode == PreviewInteractionMode.annotate
          ? 'Building Flora screen map...'
          : 'Returning to Use App mode...';
    });

    if (!mounted) {
      return;
    }

    if (mode == PreviewInteractionMode.annotate) {
      await _refreshAnnotationSnapshot(
        preserveSelection: true,
        statusOverride: 'Building Flora screen map...',
      );
    }

    setState(() {
      _interactionModeBusy = false;
      _status = mode == PreviewInteractionMode.annotate
          ? (_annotationSnapshot == null
                ? 'Annotate UI ready. Refresh once the current screen settles.'
                : 'Annotate UI ready. Browse the screen map below.')
          : 'Use App mode on. Your selected target stays attached until you clear it.';
    });
    _requestPreviewFocus();
  }

  Future<void> _togglePreviewInteractionMode() {
    final currentMode = ref.read(previewInteractionModeProvider);
    return _setPreviewInteractionMode(
      currentMode == PreviewInteractionMode.annotate
          ? PreviewInteractionMode.use
          : PreviewInteractionMode.annotate,
    );
  }

  Future<void> _refreshAnnotationSnapshot({
    required bool preserveSelection,
    String? statusOverride,
  }) async {
    final vmServiceUrl = _vmServiceUrl;
    final projectRoot = ref.read(projectRootProvider);
    if (vmServiceUrl == null ||
        projectRoot == null ||
        projectRoot.trim().isEmpty) {
      return;
    }

    final requestId = ++_annotationRefreshRequestId;
    setState(() {
      _loadingAnnotationSnapshot = true;
      if (statusOverride != null) {
        _status = statusOverride;
      }
    });

    try {
      final snapshot = await FlutterInspectorService.fetchAnnotationSnapshot(
        vmServiceUrl: vmServiceUrl,
        projectRoot: projectRoot,
        groupName: _annotationTreeGroupName,
      );
      if (!mounted || requestId != _annotationRefreshRequestId) {
        return;
      }

      InspectorTreeNode? nextSelected;
      if (snapshot != null && preserveSelection) {
        nextSelected = _resolveAnnotationSelection(snapshot);
      }
      nextSelected ??= _firstSuggestedNode(snapshot?.rootNodes ?? const []);

      setState(() {
        _annotationSnapshot = snapshot;
        _loadingAnnotationSnapshot = false;
        _status = snapshot == null
            ? 'The screen map is not available yet. Let the current frame settle and refresh again.'
            : 'Screen map refreshed. ${snapshot.layoutNodeCount} layout nodes across ${snapshot.totalNodeCount} captured nodes.';
      });

      if (snapshot == null) {
        return;
      }

      if (nextSelected != null) {
        await _selectAnnotationNode(nextSelected, fromRefresh: true);
      }
    } catch (_) {
      if (!mounted || requestId != _annotationRefreshRequestId) {
        return;
      }

      setState(() {
        _loadingAnnotationSnapshot = false;
        _status = 'Failed to refresh Flora\'s screen map.';
      });
    }
  }

  InspectorTreeNode? _resolveAnnotationSelection(
    InspectorTreeSnapshot snapshot,
  ) {
    final stableKey = _selectedAnnotationStableKey;
    if (stableKey != null) {
      final match = _findAnnotationNodeByStableKey(
        snapshot.rootNodes,
        stableKey,
      );
      if (match != null) {
        return match;
      }
    }

    final currentSelection = ref.read(inspectorSelectionProvider);
    if (currentSelection == null) {
      return null;
    }

    return _findAnnotationNodeMatchingSelection(
      snapshot.rootNodes,
      currentSelection,
    );
  }

  InspectorTreeNode? _firstSuggestedNode(List<InspectorTreeNode> roots) {
    InspectorTreeNode? fallback;

    InspectorTreeNode? walk(InspectorTreeNode node) {
      fallback ??= node;
      if (_matchesAnnotationFilter(node, _AnnotationNodeFilter.layout)) {
        return node;
      }
      for (final child in node.children) {
        final match = walk(child);
        if (match != null) {
          return match;
        }
      }
      return null;
    }

    for (final root in roots) {
      final match = walk(root);
      if (match != null) {
        return match;
      }
    }

    return fallback;
  }

  InspectorTreeNode? _findAnnotationNodeByStableKey(
    List<InspectorTreeNode> nodes,
    String stableKey,
  ) {
    for (final node in nodes) {
      if (node.stableKey == stableKey) {
        return node;
      }
      final child = _findAnnotationNodeByStableKey(node.children, stableKey);
      if (child != null) {
        return child;
      }
    }
    return null;
  }

  InspectorTreeNode? _findAnnotationNodeMatchingSelection(
    List<InspectorTreeNode> nodes,
    InspectorSelectionContext selection,
  ) {
    for (final node in nodes) {
      if (_annotationNodeMatchesSelection(node, selection)) {
        return node;
      }
      final child = _findAnnotationNodeMatchingSelection(
        node.children,
        selection,
      );
      if (child != null) {
        return child;
      }
    }
    return null;
  }

  bool _annotationNodeMatchesSelection(
    InspectorTreeNode node,
    InspectorSelectionContext selection,
  ) {
    return node.widgetName == selection.widgetName &&
        node.sourceFile == selection.sourceFile &&
        node.line == selection.line &&
        node.endLine == selection.endLine &&
        node.column == selection.column;
  }

  bool _matchesAnnotationFilter(
    InspectorTreeNode node,
    _AnnotationNodeFilter filter,
  ) {
    final name = node.widgetName.toLowerCase();
    switch (filter) {
      case _AnnotationNodeFilter.layout:
        return _matchesAnnotationKeyword(name, const <String>{
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
          'card',
          'decoratedbox',
          'coloredbox',
          'clip',
          'constrainedbox',
          'fractionallysizedbox',
          'aspectratio',
        });
      case _AnnotationNodeFilter.controls:
        return _matchesAnnotationKeyword(name, const <String>{
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
        });
      case _AnnotationNodeFilter.text:
        return _matchesAnnotationKeyword(name, const <String>{
          'text',
          'richtext',
          'selectabletext',
          'editabletext',
        });
      case _AnnotationNodeFilter.all:
        return true;
    }
  }

  bool _matchesAnnotationKeyword(String value, Set<String> fragments) {
    return fragments.any(value.contains);
  }

  Future<void> _selectAnnotationNode(
    InspectorTreeNode node, {
    bool fromRefresh = false,
  }) async {
    _selectedAnnotationStableKey = node.stableKey;
    final selection = node.toSelectionContext();
    ref.read(inspectorSelectionProvider.notifier).state = selection;
    _rememberInspectorSelection(selection);
    if (node.sourceFile != null && node.sourceFile!.trim().isNotEmpty) {
      ref.read(activeFilePathProvider.notifier).state = node.sourceFile;
    }

    setState(() {
      _loadingSelectionDetails = true;
      if (!fromRefresh) {
        _status = 'Inspecting ${node.widgetName}...';
      }
    });

    final snapshot = _annotationSnapshot;
    final vmServiceUrl = _vmServiceUrl;
    if (snapshot == null || vmServiceUrl == null || node.valueId == null) {
      setState(() {
        _loadingSelectionDetails = false;
        _selectedLayoutDetails = null;
        _selectedScreenshotBytes = null;
        _status = 'Selected ${node.widgetName} from the screen map.';
      });
      return;
    }

    final stableKey = node.stableKey;
    try {
      await FlutterInspectorService.setSelectionById(
        vmServiceUrl: vmServiceUrl,
        valueId: node.valueId!,
        groupName: snapshot.groupName,
      );
      final results = await Future.wait<Object?>(<Future<Object?>>[
        FlutterInspectorService.fetchLayoutDetails(
          vmServiceUrl: vmServiceUrl,
          valueId: node.valueId!,
          groupName: snapshot.groupName,
        ),
        FlutterInspectorService.screenshotNode(
          vmServiceUrl: vmServiceUrl,
          valueId: node.valueId!,
        ),
      ]);

      if (!mounted || _selectedAnnotationStableKey != stableKey) {
        return;
      }

      setState(() {
        _loadingSelectionDetails = false;
        _selectedLayoutDetails = results[0] as InspectorNodeLayoutDetails?;
        _selectedScreenshotBytes = results[1] as Uint8List?;
        _status = fromRefresh
            ? 'Screen map refreshed around ${node.widgetName}.'
            : 'Selected ${node.widgetName} from the screen map.';
      });
    } catch (_) {
      if (!mounted || _selectedAnnotationStableKey != stableKey) {
        return;
      }

      setState(() {
        _loadingSelectionDetails = false;
        _selectedLayoutDetails = null;
        _selectedScreenshotBytes = null;
        _status =
            'Selected ${node.widgetName}, but detailed layout metadata could not be loaded.';
      });
    }
  }

  KeyEventResult _onPreviewKeyEvent(FocusNode node, KeyEvent event) {
    if (_showSettings || !_runningFlutter) {
      return KeyEventResult.ignored;
    }

    final isControlKey =
        event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight ||
        event.logicalKey == LogicalKeyboardKey.control;
    if (!isControlKey) {
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent) {
      if (_ctrlToggleArmed) {
        return KeyEventResult.handled;
      }
      _ctrlToggleArmed = true;
      unawaited(_togglePreviewInteractionMode());
      return KeyEventResult.handled;
    }

    if (event is KeyUpEvent) {
      _ctrlToggleArmed = false;
      return KeyEventResult.handled;
    }

    return KeyEventResult.handled;
  }

  void _rememberInspectorSelection(InspectorSelectionContext selection) {
    final history = ref.read(inspectorSelectionHistoryProvider);
    final nextHistory = <InspectorSelectionContext>[
      selection,
      ...history.where((entry) => !_sameInspectorSelection(entry, selection)),
    ];
    ref.read(inspectorSelectionHistoryProvider.notifier).state = nextHistory
        .take(6)
        .toList(growable: false);
  }

  void _focusSelectionSource(InspectorSelectionContext selection) {
    final sourceFile = selection.sourceFile;
    if (sourceFile == null || sourceFile.trim().isEmpty) {
      return;
    }

    ref.read(activeFilePathProvider.notifier).state = sourceFile;
    setState(() {
      _status =
          'Focused ${p.basename(sourceFile)} from the selected UI target.';
    });
  }

  void _queueAnnotationPrompt(
    PromptTemplate template,
    InspectorSelectionContext selection,
  ) {
    final sourceLabel = selection.sourceFile == null
        ? selection.widgetName
        : '${selection.widgetName} in ${p.basename(selection.sourceFile!)}';
    final prompt = StringBuffer()
      ..writeln(template.commandHint)
      ..writeln('Focus on the currently selected widget: $sourceLabel.')
      ..writeln(
        'Keep the work scoped to this target unless a nearby structural adjustment is clearly required.',
      );

    final existingDraft = ref.read(chatComposerTextProvider).trim();
    final nextDraft = existingDraft.isEmpty
        ? prompt.toString().trim()
        : '$existingDraft\n\n${prompt.toString().trim()}';

    ref.read(chatComposerTextProvider.notifier).state = nextDraft;
    _focusSelectionSource(selection);
    setState(() {
      _status =
          'Drafted a ${template.title.toLowerCase()} request for ${selection.widgetName}.';
    });
  }

  void _selectInspectorTarget(InspectorSelectionContext selection) {
    ref.read(inspectorSelectionProvider.notifier).state = selection;
    _rememberInspectorSelection(selection);
    if (selection.sourceFile != null &&
        selection.sourceFile!.trim().isNotEmpty) {
      ref.read(activeFilePathProvider.notifier).state = selection.sourceFile;
    }

    final snapshot = _annotationSnapshot;
    if (snapshot != null) {
      final node = _findAnnotationNodeMatchingSelection(
        snapshot.rootNodes,
        selection,
      );
      if (node != null) {
        unawaited(_selectAnnotationNode(node));
        return;
      }
    }

    setState(() {
      _status = 'Selected ${selection.widgetName} for follow-up changes.';
    });
  }

  bool _sameInspectorSelection(
    InspectorSelectionContext? a,
    InspectorSelectionContext? b,
  ) {
    if (a == null || b == null) {
      return false;
    }

    return a.sourceFile == b.sourceFile &&
        a.line == b.line &&
        a.endLine == b.endLine &&
        a.column == b.column &&
        a.widgetName == b.widgetName;
  }

  void _stopInspectorSync() {
    _annotationRefreshTimer?.cancel();
    _inspectorDefaultsApplied = false;
    _interactionModeBusy = false;
    _ctrlToggleArmed = false;
    _loadingAnnotationSnapshot = false;
    _loadingSelectionDetails = false;
    _annotationSnapshot = null;
    _selectedLayoutDetails = null;
    _selectedScreenshotBytes = null;
    _selectedAnnotationStableKey = null;
    ref.read(previewInteractionModeProvider.notifier).state =
        PreviewInteractionMode.use;
  }

  Future<void> _stopFlutterRun() async {
    final process = _flutterProcess;
    if (process == null) {
      return;
    }

    setState(() {
      _status = 'Stopping flutter run...';
      _runningFlutter = false;
    });

    process.kill();
    _devToolsProcess?.kill();

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    await _devToolsStdoutSub?.cancel();
    await _devToolsStderrSub?.cancel();

    _stdoutSub = null;
    _stderrSub = null;
    _devToolsStdoutSub = null;
    _devToolsStderrSub = null;
    _flutterProcess = null;
    _devToolsProcess = null;
    final vmServiceUrl = _vmServiceUrl;
    _vmServiceUrl = null;
    if (vmServiceUrl != null) {
      unawaited(
        FlutterInspectorService.disposeGroup(
          vmServiceUrl: vmServiceUrl,
          groupName: _annotationTreeGroupName,
        ),
      );
    }
    _stopInspectorSync();

    if (!mounted) {
      return;
    }

    setState(() {
      _status = 'Flutter run stopped';
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(hotReloadTriggerProvider, (previous, next) {
      if (next > (previous ?? 0)) {
        _hotReloadDebounceTimer?.cancel();
        _hotReloadDebounceTimer = Timer(const Duration(milliseconds: 500), () {
          _sendFlutterCommand('r');
          _annotationRefreshTimer?.cancel();
          if (ref.read(previewInteractionModeProvider) ==
              PreviewInteractionMode.annotate) {
            _annotationRefreshTimer = Timer(
              const Duration(milliseconds: 1100),
              () => unawaited(
                _refreshAnnotationSnapshot(
                  preserveSelection: true,
                  statusOverride:
                      'Refreshing the screen map after hot reload...',
                ),
              ),
            );
          }
        });
      }
    });
    ref.listen<String?>(projectRootProvider, (previous, next) {
      _handleProjectRootChanged(next);
    });

    final hasProjectRoot = (ref.watch(projectRootProvider) ?? '')
        .trim()
        .isNotEmpty;
    final interactionMode = ref.watch(previewInteractionModeProvider);
    final inspectorSelection = ref.watch(inspectorSelectionProvider);
    final inspectorHistory = ref.watch(inspectorSelectionHistoryProvider);
    final selectedAnnotationNode =
        _annotationSnapshot == null || _selectedAnnotationStableKey == null
        ? null
        : _findAnnotationNodeByStableKey(
            _annotationSnapshot!.rootNodes,
            _selectedAnnotationStableKey!,
          );

    return Focus(
      focusNode: _previewFocusNode,
      autofocus: true,
      onKeyEvent: _onPreviewKeyEvent,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _requestPreviewFocus,
        child: Container(
          color: FloraPalette.background, // Match apple clean background
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 32, // Apple slightly taller toolbar
                decoration: const BoxDecoration(
                  color: FloraPalette.panelBg,
                  border: Border(
                    bottom: BorderSide(color: FloraPalette.border, width: 0.5),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    const Text(
                      'PREVIEW',
                      style: TextStyle(
                        color: FloraPalette.textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                    if (_runningFlutter) ...[
                      const SizedBox(width: 8),
                      Text(
                        interactionMode == PreviewInteractionMode.annotate
                            ? 'mode:annotate-ui'
                            : 'mode:use-app',
                        style: FloraTheme.mono(
                          size: 10,
                          color: FloraPalette.textDimmed,
                        ),
                      ),
                    ],
                    const SizedBox(width: 12),
                    _BuildTypePill(
                      buildType: _selectedBuildType,
                      onSelected: _runningFlutter ? null : _setBuildType,
                    ),
                    const SizedBox(width: 12),

                    // Condense the main actions into this toolbar directly
                    if (hasProjectRoot) ...[
                      if (!_runningFlutter)
                        InkWell(
                          onTap: _runAndLoadPreview,
                          child: const _ToolbarIcon(
                            Icons.play_arrow,
                            color: FloraPalette.success,
                          ),
                        )
                      else
                        InkWell(
                          onTap: _stopFlutterRun,
                          child: const _ToolbarIcon(
                            Icons.stop,
                            color: FloraPalette.error,
                          ),
                        ),

                      if (_runningFlutter) ...[
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => _sendFlutterCommand('r'),
                          child: const _ToolbarIcon(
                            Icons.bolt,
                            tooltip: 'Hot Reload',
                          ),
                        ),
                        InkWell(
                          onTap: () => _sendFlutterCommand('R'),
                          child: const _ToolbarIcon(
                            Icons.restart_alt,
                            tooltip: 'Hot Restart',
                          ),
                        ),
                        const SizedBox(width: 8),
                        _InteractionModeToggle(
                          mode: interactionMode,
                          busy: _interactionModeBusy,
                          onChanged: _setPreviewInteractionMode,
                        ),
                      ],
                    ],

                    const Spacer(),

                    if (_appWebviewInitialized || _devToolsWebviewInitialized)
                      InkWell(
                        onTap: _loadingPreview || _loadingDevTools
                            ? null
                            : () {
                                if (_activeTab == _PreviewTab.app &&
                                    _appWebviewInitialized) {
                                  _appWebview.reload();
                                }
                                if (_activeTab == _PreviewTab.devTools &&
                                    _devToolsWebviewInitialized) {
                                  _devToolsWebview.reload();
                                }
                              },
                        child: const _ToolbarIcon(
                          Icons.refresh,
                          tooltip: 'Reload Webview',
                        ),
                      ),

                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () =>
                          setState(() => _showSettings = !_showSettings),
                      child: _ToolbarIcon(
                        _showSettings
                            ? Icons.keyboard_arrow_up
                            : Icons.settings_outlined,
                        tooltip: 'Preview Settings',
                      ),
                    ),
                  ],
                ),
              ),

              if (_showSettings)
                Container(
                  color: FloraPalette.sidebarBg,
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _BuildTypePill(
                            buildType: _selectedBuildType,
                            onSelected: _runningFlutter ? null : _setBuildType,
                            expanded: true,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _runCommandCtrl,
                              readOnly: true,
                              style: FloraTheme.mono(size: 11),
                              decoration: const InputDecoration(
                                hintText:
                                    'e.g., flutter run -d web-server --web-hostname 127.0.0.1',
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _urlCtrl,
                              style: FloraTheme.mono(size: 11),
                              decoration: const InputDecoration(
                                hintText:
                                    'DevTools URL (optional manual override)',
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                              ),
                              onSubmitted: _loadDevTools,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _TinyButton(
                            label: 'Load DevTools',
                            onTap: _loadingDevTools
                                ? null
                                : () => _loadDevTools(_urlCtrl.text.trim()),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _status,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: FloraPalette.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),

              if (!_showSettings && _status != 'Idle' && _status.isNotEmpty)
                Container(
                  color: FloraPalette.panelBg,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _status,
                    style: const TextStyle(
                      fontSize: 10,
                      color: FloraPalette.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

              if (_runningFlutter)
                _AnnotationWorkbench(
                  mode: interactionMode,
                  snapshot: _annotationSnapshot,
                  selection: inspectorSelection,
                  selectedNode: selectedAnnotationNode,
                  selectedLayoutDetails: _selectedLayoutDetails,
                  selectedScreenshotBytes: _selectedScreenshotBytes,
                  history: inspectorHistory,
                  busy: _interactionModeBusy,
                  loadingSnapshot: _loadingAnnotationSnapshot,
                  loadingSelectionDetails: _loadingSelectionDetails,
                  annotationFilter: _annotationFilter,
                  searchController: _annotationSearchCtrl,
                  onModeChanged: _setPreviewInteractionMode,
                  onRefresh: () => _refreshAnnotationSnapshot(
                    preserveSelection: true,
                    statusOverride: 'Refreshing the current screen map...',
                  ),
                  onSearchChanged: (_) => setState(() {}),
                  onFilterChanged: (nextFilter) => setState(() {
                    _annotationFilter = nextFilter;
                  }),
                  onSelectNode: _selectAnnotationNode,
                  onFocusSource: inspectorSelection == null
                      ? null
                      : () => _focusSelectionSource(inspectorSelection),
                  onClearSelection: inspectorSelection == null
                      ? null
                      : () {
                          ref.read(inspectorSelectionProvider.notifier).state =
                              null;
                          setState(() {
                            _selectedAnnotationStableKey = null;
                            _selectedLayoutDetails = null;
                            _selectedScreenshotBytes = null;
                            _status = 'Cleared the current UI target.';
                          });
                        },
                  onQueuePrompt: inspectorSelection == null
                      ? null
                      : (template) => _queueAnnotationPrompt(
                          template,
                          inspectorSelection,
                        ),
                  onSelectHistory: _selectInspectorTarget,
                ),

              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_activeTab == _PreviewTab.app && _loadingPreview) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: FloraPalette.accent,
          ),
        ),
      );
    }

    if (_activeTab == _PreviewTab.devTools && _loadingDevTools) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: FloraPalette.accent,
          ),
        ),
      );
    }

    if (_error != null) {
      return _Placeholder(
        icon: Icons.error_outline,
        title: 'Preview error',
        subtitle: _error!,
        logs: _logs,
        color: FloraPalette.error,
      );
    }

    if (_activeTab == _PreviewTab.app && !_appWebviewInitialized) {
      return _Placeholder(
        icon: Icons.play_circle_outline,
        title: 'No app preview',
        subtitle:
            'Run with the default web-server command to keep the app inside Flora.',
        logs: _logs,
      );
    }

    if (_activeTab == _PreviewTab.devTools && !_devToolsWebviewInitialized) {
      return _Placeholder(
        icon: Icons.bug_report_outlined,
        title: 'No DevTools session',
        subtitle:
            'Run & Load first, then open DevTools only when you need the raw Flutter inspector tools.',
        logs: _logs,
      );
    }

    return Column(
      children: [
        Container(
          height: 30,
          color: FloraPalette.panelBg,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              _TabChip(
                label: 'App',
                active: _activeTab == _PreviewTab.app,
                onTap: () => setState(() => _activeTab = _PreviewTab.app),
              ),
              const SizedBox(width: 6),
              _TabChip(
                label: 'DevTools',
                active: _activeTab == _PreviewTab.devTools,
                onTap: _openDevToolsTab,
              ),
              const Spacer(),
              if (_activeTab == _PreviewTab.app && _appUrl != null)
                Flexible(
                  child: Text(
                    _appUrl!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FloraTheme.mono(
                      size: 10,
                      color: FloraPalette.textDimmed,
                    ),
                  ),
                ),
              if (_activeTab == _PreviewTab.devTools && _devToolsUrl != null)
                Flexible(
                  child: Text(
                    _devToolsUrl!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FloraTheme.mono(
                      size: 10,
                      color: FloraPalette.textDimmed,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Webview(
            _activeTab == _PreviewTab.app ? _appWebview : _devToolsWebview,
            permissionRequested: (url, kind, isUser) =>
                WebviewPermissionDecision.allow,
          ),
        ),
      ],
    );
  }
}

enum _PreviewTab { app, devTools }

enum _PreviewBuildType { web, app, mobile }

extension on _PreviewBuildType {
  String get label {
    switch (this) {
      case _PreviewBuildType.web:
        return 'Web';
      case _PreviewBuildType.app:
        return 'App';
      case _PreviewBuildType.mobile:
        return 'Mobile';
    }
  }
}

class _BuildTypePill extends StatelessWidget {
  const _BuildTypePill({
    required this.buildType,
    required this.onSelected,
    this.expanded = false,
  });

  final _PreviewBuildType buildType;
  final void Function(_PreviewBuildType)? onSelected;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final button = PopupMenuButton<_PreviewBuildType>(
      enabled: onSelected != null,
      tooltip: 'Select build type',
      onSelected: onSelected,
      itemBuilder: (context) => _PreviewBuildType.values
          .map(
            (type) => PopupMenuItem<_PreviewBuildType>(
              value: type,
              child: Text(type.label),
            ),
          )
          .toList(),
      child: Container(
        height: expanded ? 32 : 22,
        padding: EdgeInsets.symmetric(horizontal: expanded ? 10 : 8),
        decoration: BoxDecoration(
          color: FloraPalette.panelBg,
          border: Border.all(color: FloraPalette.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.developer_mode_outlined,
              size: 12,
              color: FloraPalette.textDimmed,
            ),
            const SizedBox(width: 4),
            Text(
              'Build: ${buildType.label}',
              style: TextStyle(
                color: onSelected == null
                    ? FloraPalette.textDimmed
                    : FloraPalette.textSecondary,
                fontSize: expanded ? 11 : 10,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              Icons.keyboard_arrow_down,
              size: 12,
              color: FloraPalette.textDimmed,
            ),
          ],
        ),
      ),
    );

    if (!expanded) {
      return button;
    }

    return Expanded(child: button);
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? FloraPalette.accent : FloraPalette.background,
          border: Border.all(color: FloraPalette.border),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : FloraPalette.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _TinyButton extends StatelessWidget {
  const _TinyButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: !enabled ? FloraPalette.border : FloraPalette.panelBg,
          border: Border.all(color: FloraPalette.border),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: enabled ? FloraPalette.textPrimary : FloraPalette.textDimmed,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _InteractionModeToggle extends StatelessWidget {
  const _InteractionModeToggle({
    required this.mode,
    required this.busy,
    required this.onChanged,
  });

  final PreviewInteractionMode mode;
  final bool busy;
  final ValueChanged<PreviewInteractionMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: FloraPalette.background,
        border: Border.all(color: FloraPalette.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: PreviewInteractionMode.values
            .map((entry) {
              final active = entry == mode;
              return InkWell(
                onTap: busy ? null : () => onChanged(entry),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: active ? FloraPalette.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    entry.label,
                    style: TextStyle(
                      color: active ? Colors.white : FloraPalette.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              );
            })
            .toList(growable: false),
      ),
    );
  }
}

class _AnnotationWorkbench extends StatelessWidget {
  const _AnnotationWorkbench({
    required this.mode,
    required this.snapshot,
    required this.selection,
    required this.selectedNode,
    required this.selectedLayoutDetails,
    required this.selectedScreenshotBytes,
    required this.history,
    required this.busy,
    required this.loadingSnapshot,
    required this.loadingSelectionDetails,
    required this.annotationFilter,
    required this.searchController,
    required this.onModeChanged,
    required this.onRefresh,
    required this.onSearchChanged,
    required this.onFilterChanged,
    required this.onSelectNode,
    required this.onFocusSource,
    required this.onClearSelection,
    required this.onQueuePrompt,
    required this.onSelectHistory,
  });

  final PreviewInteractionMode mode;
  final InspectorTreeSnapshot? snapshot;
  final InspectorSelectionContext? selection;
  final InspectorTreeNode? selectedNode;
  final InspectorNodeLayoutDetails? selectedLayoutDetails;
  final Uint8List? selectedScreenshotBytes;
  final List<InspectorSelectionContext> history;
  final bool busy;
  final bool loadingSnapshot;
  final bool loadingSelectionDetails;
  final _AnnotationNodeFilter annotationFilter;
  final TextEditingController searchController;
  final ValueChanged<PreviewInteractionMode> onModeChanged;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<_AnnotationNodeFilter> onFilterChanged;
  final ValueChanged<InspectorTreeNode> onSelectNode;
  final VoidCallback? onFocusSource;
  final VoidCallback? onClearSelection;
  final ValueChanged<PromptTemplate>? onQueuePrompt;
  final ValueChanged<InspectorSelectionContext> onSelectHistory;

  @override
  Widget build(BuildContext context) {
    final recentTargets = history
        .where((entry) => !_sameSelection(entry, selection))
        .take(4)
        .toList(growable: false);
    final locationLabel = _selectionLocation(selection);
    final ancestryLabel = selection == null || selection!.ancestorPath.isEmpty
        ? null
        : selection!.ancestorPath.reversed.take(6).join(' > ');
    final query = searchController.text.trim().toLowerCase();
    final visibleNodes = snapshot == null
        ? const <_VisibleAnnotationNode>[]
        : snapshot!.rootNodes
              .expand(
                (node) => _visibleEntriesFor(
                  node,
                  query: query,
                  filter: annotationFilter,
                ),
              )
              .toList(growable: false);

    return Container(
      color: FloraPalette.sidebarBg,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: FloraPalette.panelBg,
          border: Border.all(color: FloraPalette.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.design_services_outlined,
                  size: 14,
                  color: FloraPalette.textSecondary,
                ),
                const SizedBox(width: 6),
                const Text(
                  'Flora Screen Map',
                  style: TextStyle(
                    color: FloraPalette.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                _TinyButton(
                  label: loadingSnapshot ? 'Refreshing...' : 'Refresh Map',
                  onTap: busy || loadingSnapshot
                      ? null
                      : () => unawaited(onRefresh()),
                ),
                const SizedBox(width: 8),
                _InteractionModeToggle(
                  mode: mode,
                  busy: busy,
                  onChanged: onModeChanged,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              mode == PreviewInteractionMode.annotate
                  ? 'Browse the current widget structure without freezing the live preview. Search by widget, source file, or text, then target the right container directly.'
                  : selection == null
                  ? mode.helperText
                  : 'Your current target stays attached while you use the app. Switch back to Annotate UI when you want to retarget or inspect structure again.',
              style: const TextStyle(
                color: FloraPalette.textSecondary,
                fontSize: 11,
                height: 1.4,
              ),
            ),
            if (snapshot != null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _SelectionInfoChip(
                    icon: Icons.view_quilt_outlined,
                    text: '${snapshot!.layoutNodeCount} layout',
                  ),
                  _SelectionInfoChip(
                    icon: Icons.smart_button_outlined,
                    text: '${snapshot!.controlNodeCount} controls',
                  ),
                  _SelectionInfoChip(
                    icon: Icons.text_fields,
                    text: '${snapshot!.textNodeCount} text',
                  ),
                  _SelectionInfoChip(
                    icon: Icons.widgets_outlined,
                    text: '${snapshot!.totalNodeCount} total',
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            if (mode == PreviewInteractionMode.annotate) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: searchController,
                      onChanged: onSearchChanged,
                      style: FloraTheme.mono(size: 11),
                      decoration: const InputDecoration(
                        hintText: 'Search widget, source file, or text preview',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          size: 16,
                          color: FloraPalette.textDimmed,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _AnnotationNodeFilter.values
                    .map(
                      (entry) => _FilterChip(
                        label: entry.label,
                        active: annotationFilter == entry,
                        onTap: () => onFilterChanged(entry),
                      ),
                    )
                    .toList(growable: false),
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final stacked = constraints.maxWidth < 860;
                  final treePane = _buildTreePane(
                    visibleNodes: visibleNodes,
                    query: query,
                  );
                  final detailsPane = _buildDetailsPane(
                    selection: selection,
                    locationLabel: locationLabel,
                    ancestryLabel: ancestryLabel,
                    recentTargets: recentTargets,
                  );

                  return SizedBox(
                    height: stacked ? 480 : 320,
                    child: stacked
                        ? Column(
                            children: [
                              Expanded(child: treePane),
                              const SizedBox(height: 10),
                              Expanded(child: detailsPane),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(flex: 11, child: treePane),
                              const SizedBox(width: 10),
                              Expanded(flex: 10, child: detailsPane),
                            ],
                          ),
                  );
                },
              ),
            ] else ...[
              _buildDetailsPane(
                selection: selection,
                locationLabel: locationLabel,
                ancestryLabel: ancestryLabel,
                recentTargets: recentTargets,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTreePane({
    required List<_VisibleAnnotationNode> visibleNodes,
    required String query,
  }) {
    if (loadingSnapshot) {
      return _panelShell(
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: FloraPalette.accent,
            ),
          ),
        ),
      );
    }

    if (snapshot == null) {
      return _panelShell(
        child: _panelMessage(
          icon: Icons.layers_clear_outlined,
          title: 'No screen map yet',
          subtitle:
              'Refresh once the current frame settles. Flora will pull the active widget summary tree directly from the running app.',
        ),
      );
    }

    if (visibleNodes.isEmpty) {
      return _panelShell(
        child: _panelMessage(
          icon: Icons.filter_alt_off_outlined,
          title: 'No matching nodes',
          subtitle: query.isEmpty
              ? 'The current filter does not match anything in the captured tree.'
              : 'Try a broader search term or switch the active filter.',
        ),
      );
    }

    return _panelShell(
      child: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: visibleNodes.length,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (context, index) {
          final entry = visibleNodes[index];
          final node = entry.node;
          final selected = selectedNode?.stableKey == node.stableKey;
          final meta = _nodeMetaLabel(node);

          return InkWell(
            onTap: () => onSelectNode(node),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: EdgeInsets.fromLTRB(
                10 + (node.depth * 14).toDouble(),
                8,
                10,
                8,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0x14007AFF)
                    : entry.directMatch
                    ? FloraPalette.background
                    : FloraPalette.panelBg,
                border: Border.all(
                  color: selected ? FloraPalette.accent : FloraPalette.border,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _nodeIcon(node),
                    size: 14,
                    color: selected
                        ? FloraPalette.accent
                        : FloraPalette.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          node.widgetName,
                          style: TextStyle(
                            color: entry.directMatch
                                ? FloraPalette.textPrimary
                                : FloraPalette.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (node.textPreview != null &&
                            node.textPreview!.trim().isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            node.textPreview!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: FloraPalette.textSecondary,
                              fontSize: 10,
                            ),
                          ),
                        ],
                        const SizedBox(height: 3),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: FloraTheme.mono(
                            size: 10,
                            color: FloraPalette.textDimmed,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected)
                    const Icon(
                      Icons.check_circle,
                      size: 14,
                      color: FloraPalette.accent,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDetailsPane({
    required InspectorSelectionContext? selection,
    required String locationLabel,
    required String? ancestryLabel,
    required List<InspectorSelectionContext> recentTargets,
  }) {
    return _panelShell(
      child: selectedNode == null || selection == null
          ? Padding(
              padding: const EdgeInsets.all(14),
              child: _panelMessage(
                icon: Icons.ads_click_outlined,
                title: 'No target selected',
                subtitle: mode == PreviewInteractionMode.annotate
                    ? 'Pick a node from the screen map to inspect its layout, source, and screenshot.'
                    : 'Switch to Annotate UI and target a node when you want scoped UI changes.',
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          selection.widgetName,
                          style: const TextStyle(
                            color: FloraPalette.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        _relativeTimestamp(selection.capturedAt),
                        style: FloraTheme.mono(
                          size: 10,
                          color: FloraPalette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    selectedNode!.description,
                    style: const TextStyle(
                      color: FloraPalette.textSecondary,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _SelectionInfoChip(
                        icon: Icons.insert_drive_file_outlined,
                        text: locationLabel,
                      ),
                      if (ancestryLabel != null)
                        _SelectionInfoChip(
                          icon: Icons.account_tree_outlined,
                          text: ancestryLabel,
                        ),
                      if (selectedLayoutDetails?.constraintsDescription != null)
                        _SelectionInfoChip(
                          icon: Icons.straighten_outlined,
                          text: selectedLayoutDetails!.constraintsDescription!,
                        ),
                      if (selectedLayoutDetails?.width != null &&
                          selectedLayoutDetails?.height != null)
                        _SelectionInfoChip(
                          icon: Icons.crop_free_outlined,
                          text:
                              '${selectedLayoutDetails!.width!.toStringAsFixed(0)} x ${selectedLayoutDetails!.height!.toStringAsFixed(0)}',
                        ),
                      if (selectedLayoutDetails?.flexFactor != null)
                        _SelectionInfoChip(
                          icon: Icons.view_stream_outlined,
                          text:
                              'flex ${selectedLayoutDetails!.flexFactor}${selectedLayoutDetails!.flexFit == null ? '' : ' ${selectedLayoutDetails!.flexFit}'}',
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (loadingSelectionDetails)
                    const LinearProgressIndicator(
                      minHeight: 2,
                      color: FloraPalette.accent,
                      backgroundColor: FloraPalette.border,
                    )
                  else if (selectedScreenshotBytes != null)
                    Container(
                      width: double.infinity,
                      height: 150,
                      decoration: BoxDecoration(
                        color: FloraPalette.background,
                        border: Border.all(color: FloraPalette.border),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.memory(
                        selectedScreenshotBytes!,
                        fit: BoxFit.contain,
                      ),
                    )
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: FloraPalette.background,
                        border: Border.all(color: FloraPalette.border),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'No screenshot preview is available for this node yet.',
                        style: TextStyle(
                          color: FloraPalette.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (onFocusSource != null)
                        _TrayActionButton(
                          label: 'Focus Source',
                          icon: Icons.code_outlined,
                          onTap: onFocusSource,
                        ),
                      if (onClearSelection != null)
                        _TrayActionButton(
                          label: 'Clear Target',
                          icon: Icons.close,
                          onTap: onClearSelection,
                        ),
                      for (final template in _annotationPromptTemplates)
                        _TrayActionButton(
                          label: template.title,
                          icon: Icons.auto_awesome_outlined,
                          tooltip: template.summary,
                          onTap: onQueuePrompt == null
                              ? null
                              : () => onQueuePrompt!(template),
                        ),
                    ],
                  ),
                  if (recentTargets.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Recent targets',
                      style: TextStyle(
                        color: FloraPalette.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: recentTargets
                          .map(
                            (entry) => _RecentTargetChip(
                              selection: entry,
                              onTap: () => onSelectHistory(entry),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _panelShell({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: FloraPalette.background,
        border: Border.all(color: FloraPalette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }

  Widget _panelMessage({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: FloraPalette.textDimmed),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                color: FloraPalette.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                color: FloraPalette.textSecondary,
                fontSize: 11,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  List<_VisibleAnnotationNode> _visibleEntriesFor(
    InspectorTreeNode node, {
    required String query,
    required _AnnotationNodeFilter filter,
  }) {
    final children = node.children
        .expand(
          (child) => _visibleEntriesFor(child, query: query, filter: filter),
        )
        .toList(growable: false);
    final directMatch = _nodeMatches(node, query: query, filter: filter);
    if (!directMatch && children.isEmpty) {
      return const <_VisibleAnnotationNode>[];
    }
    return <_VisibleAnnotationNode>[
      _VisibleAnnotationNode(node: node, directMatch: directMatch),
      ...children,
    ];
  }

  bool _nodeMatches(
    InspectorTreeNode node, {
    required String query,
    required _AnnotationNodeFilter filter,
  }) {
    if (!_matchesFilter(node, filter)) {
      return false;
    }
    if (query.isEmpty) {
      return true;
    }

    final haystack = <String>[
      node.widgetName,
      node.description,
      node.textPreview ?? '',
      node.sourceFile == null ? '' : p.basename(node.sourceFile!),
    ].join(' ').toLowerCase();
    return haystack.contains(query);
  }

  bool _matchesFilter(InspectorTreeNode node, _AnnotationNodeFilter filter) {
    final name = node.widgetName.toLowerCase();
    switch (filter) {
      case _AnnotationNodeFilter.layout:
        return _containsAny(name, const <String>{
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
          'card',
          'decoratedbox',
          'coloredbox',
          'clip',
          'constrainedbox',
          'fractionallysizedbox',
          'aspectratio',
        });
      case _AnnotationNodeFilter.controls:
        return _containsAny(name, const <String>{
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
        });
      case _AnnotationNodeFilter.text:
        return _containsAny(name, const <String>{
          'text',
          'richtext',
          'selectabletext',
          'editabletext',
        });
      case _AnnotationNodeFilter.all:
        return true;
    }
  }

  bool _containsAny(String value, Set<String> fragments) {
    return fragments.any(value.contains);
  }

  IconData _nodeIcon(InspectorTreeNode node) {
    final name = node.widgetName.toLowerCase();
    if (_containsAny(name, const <String>{
      'text',
      'richtext',
      'editabletext',
    })) {
      return Icons.text_fields;
    }
    if (_containsAny(name, const <String>{'button', 'textfield', 'switch'})) {
      return Icons.smart_button_outlined;
    }
    if (_containsAny(name, const <String>{'row', 'column', 'stack', 'flex'})) {
      return Icons.view_quilt_outlined;
    }
    return Icons.widgets_outlined;
  }

  String _nodeMetaLabel(InspectorTreeNode node) {
    final sourceFile = node.sourceFile;
    final fileLabel = sourceFile == null || sourceFile.trim().isEmpty
        ? 'framework node'
        : p.basename(sourceFile);
    final line = node.line;
    if (line == null) {
      return fileLabel;
    }
    return '$fileLabel:$line';
  }

  static bool _sameSelection(
    InspectorSelectionContext entry,
    InspectorSelectionContext? current,
  ) {
    if (current == null) {
      return false;
    }

    return entry.sourceFile == current.sourceFile &&
        entry.line == current.line &&
        entry.endLine == current.endLine &&
        entry.column == current.column &&
        entry.widgetName == current.widgetName;
  }

  static String _selectionLocation(InspectorSelectionContext? selection) {
    if (selection == null) {
      return 'No source location';
    }

    final sourceFile = selection.sourceFile;
    final fileLabel = sourceFile == null || sourceFile.trim().isEmpty
        ? 'unknown file'
        : p.basename(sourceFile);
    final startLine = selection.line;
    final endLine = selection.endLine;
    if (startLine == null) {
      return fileLabel;
    }
    if (endLine != null && endLine >= startLine) {
      return '$fileLabel:$startLine-$endLine';
    }
    return '$fileLabel:$startLine';
  }

  static String _relativeTimestamp(DateTime capturedAt) {
    final delta = DateTime.now().difference(capturedAt);
    if (delta.inSeconds < 10) {
      return 'just now';
    }
    if (delta.inMinutes < 1) {
      return '${delta.inSeconds}s ago';
    }
    if (delta.inHours < 1) {
      return '${delta.inMinutes}m ago';
    }
    return '${delta.inHours}h ago';
  }
}

class _VisibleAnnotationNode {
  const _VisibleAnnotationNode({required this.node, required this.directMatch});

  final InspectorTreeNode node;
  final bool directMatch;
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: active ? FloraPalette.accent : FloraPalette.background,
          border: Border.all(color: FloraPalette.border),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : FloraPalette.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _SelectionInfoChip extends StatelessWidget {
  const _SelectionInfoChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: FloraPalette.panelBg,
        border: Border.all(color: FloraPalette.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: FloraPalette.textSecondary),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: FloraTheme.mono(
                size: 10,
                color: FloraPalette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrayActionButton extends StatelessWidget {
  const _TrayActionButton({
    required this.label,
    required this.icon,
    this.tooltip,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: onTap == null ? FloraPalette.border : FloraPalette.background,
          border: Border.all(color: FloraPalette.border),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: FloraPalette.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: onTap == null
                    ? FloraPalette.textDimmed
                    : FloraPalette.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );

    if (tooltip == null || tooltip!.trim().isEmpty) {
      return content;
    }

    return Tooltip(message: tooltip!, child: content);
  }
}

class _RecentTargetChip extends StatelessWidget {
  const _RecentTargetChip({required this.selection, required this.onTap});

  final InspectorSelectionContext selection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final location = _AnnotationWorkbench._selectionLocation(selection);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: FloraPalette.background,
          border: Border.all(color: FloraPalette.border),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              selection.widgetName,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: FloraPalette.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              location,
              overflow: TextOverflow.ellipsis,
              style: FloraTheme.mono(
                size: 10,
                color: FloraPalette.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarIcon extends StatelessWidget {
  const _ToolbarIcon(this.icon, {this.tooltip, this.color});
  final IconData icon;
  final String? tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    Widget child = Container(
      padding: const EdgeInsets.all(4),
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
      child: Icon(icon, size: 16, color: color ?? FloraPalette.textSecondary),
    );
    if (tooltip != null) {
      child = Tooltip(message: tooltip!, child: child);
    }
    return child;
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.logs,
    this.color,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<String> logs;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: color ?? FloraPalette.textDimmed),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                color: FloraPalette.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(
                color: FloraPalette.textDimmed,
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
            if (logs.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: FloraPalette.background,
                  border: Border.all(color: FloraPalette.border),
                ),
                child: SelectableText(
                  logs.join('\n'),
                  style: FloraTheme.mono(
                    size: 10,
                    color: FloraPalette.textSecondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
