import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/theme/flora_theme.dart';
import '../../../core/models/flora_models.dart';
import '../../../core/services/copilot_cli_service.dart';
import '../../../core/services/codex_cli_service.dart';
import '../../../core/state/flora_providers.dart';

const _chatCodexModelOptions = <String>[
  'gpt-5.4-mini',
  'gpt-5.4',
  'gpt-5.3-codex',
  'gpt-5.1-codex-mini',
];

const _chatCopilotModelOptions = <String>[
  'gpt-5.2',
  'gpt-5.4',
  'gpt-5.4-mini',
  'claude-sonnet-4',
  'claude-3.7-sonnet',
  'gemini-2.5-pro',
  'gemini-2.5-flash',
  'o4-mini',
];

String _normalizeProjectPath(String value) {
  final normalized = p.normalize(p.absolute(value.trim()));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

bool _isPathInsideProjectRoot(String projectRoot, String candidatePath) {
  final normalizedRoot = _normalizeProjectPath(projectRoot);
  final normalizedPath = _normalizeProjectPath(candidatePath);
  return normalizedPath == normalizedRoot ||
      p.isWithin(normalizedRoot, normalizedPath);
}

String? _projectScopedPath(String? candidatePath, String? projectRoot) {
  if (projectRoot == null || projectRoot.trim().isEmpty) {
    return null;
  }
  if (candidatePath == null || candidatePath.trim().isEmpty) {
    return null;
  }
  return _isPathInsideProjectRoot(projectRoot, candidatePath)
      ? candidatePath
      : null;
}

bool _looksLikeDeicticTask(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) {
    return false;
  }

  return RegExp(
    r'\b(this|that|it|this one|that one|selected|remove this|delete this|change this|fix this)\b',
  ).hasMatch(normalized);
}

InspectorSelectionContext? _projectScopedInspectorSelection(
  InspectorSelectionContext? selection,
  String? projectRoot,
) {
  if (selection == null) {
    return null;
  }
  if (projectRoot == null || projectRoot.trim().isEmpty) {
    return null;
  }

  final sourceFile = selection.sourceFile;
  if (sourceFile == null || sourceFile.trim().isEmpty) {
    return null;
  }

  return _isPathInsideProjectRoot(projectRoot, sourceFile) ? selection : null;
}

List<ChatMessage> _recentPromptHistory(List<ChatMessage> history) {
  final resolved = history.where((message) {
    if (message.isStreaming) {
      return false;
    }
    if (message.role == MessageRole.system) {
      return false;
    }
    return message.content.trim().isNotEmpty;
  }).toList();

  if (resolved.length <= 6) {
    return resolved;
  }
  return resolved.sublist(resolved.length - 6);
}

String _summarizeConversationEntry(String value, {int maxChars = 220}) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.length <= maxChars) {
    return normalized;
  }
  return '${normalized.substring(0, maxChars)}...';
}

class _ProviderStatusSnapshot {
  const _ProviderStatusSnapshot({
    required this.installed,
    required this.authenticated,
    required this.badgeLabel,
    required this.mode,
    required this.message,
  });

  final bool installed;
  final bool authenticated;
  final String badgeLabel;
  final String mode;
  final String message;
}

class ChatWorkspacePane extends ConsumerStatefulWidget {
  const ChatWorkspacePane({super.key});

  @override
  ConsumerState<ChatWorkspacePane> createState() => _ChatWorkspacePaneState();
}

class _ChatWorkspacePaneState extends ConsumerState<ChatWorkspacePane> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _inputFocus = FocusNode();
  Timer? _pendingScroll;
  String? _lastSubmittedText;
  DateTime? _lastSubmittedAt;

  @override
  void initState() {
    super.initState();
    _inputCtrl.text = ref.read(chatComposerTextProvider);
    _inputCtrl.addListener(_syncComposerDraftFromInput);
  }

  @override
  void dispose() {
    _pendingScroll?.cancel();
    _inputCtrl.removeListener(_syncComposerDraftFromInput);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _syncComposerDraftFromInput() {
    final currentDraft = ref.read(chatComposerTextProvider);
    if (currentDraft == _inputCtrl.text) {
      return;
    }
    ref.read(chatComposerTextProvider.notifier).state = _inputCtrl.text;
  }

  String? _readFileExcerpt(
    String path, {
    required int? startLine,
    required int? endLine,
    int contextRadius = 4,
  }) {
    try {
      final raw = File(path).readAsStringSync();
      final lines = raw.split('\n');
      if (lines.isEmpty) {
        return null;
      }

      final anchorStart = startLine == null || startLine < 1 ? 1 : startLine;
      final anchorEnd = endLine == null || endLine < anchorStart
          ? anchorStart
          : endLine;

      final excerptStart = anchorStart - contextRadius < 1
          ? 1
          : anchorStart - contextRadius;
      final excerptEnd = anchorEnd + contextRadius > lines.length
          ? lines.length
          : anchorEnd + contextRadius;

      final excerpt = <String>[];
      for (
        var lineNumber = excerptStart;
        lineNumber <= excerptEnd;
        lineNumber++
      ) {
        excerpt.add(
          '${lineNumber.toString().padLeft(4)}: ${lines[lineNumber - 1]}',
        );
      }

      return excerpt.join('\n').trimRight();
    } catch (_) {
      return null;
    }
  }

  Future<_ProviderStatusSnapshot> _inspectProviderStatus(
    AssistantProviderType provider,
  ) async {
    if (provider == AssistantProviderType.codex) {
      final status = await CodexCliService.inspectStatus();
      return _ProviderStatusSnapshot(
        installed: status.installed,
        authenticated: status.authenticated,
        badgeLabel: status.badgeLabel,
        mode: status.mode.name,
        message: status.message,
      );
    }

    final status = await CopilotCliService.inspectStatus();
    return _ProviderStatusSnapshot(
      installed: status.installed,
      authenticated: status.authenticated,
      badgeLabel: status.badgeLabel,
      mode: status.mode.name,
      message: status.message,
    );
  }

  void _pushProviderStatus(
    AssistantProviderType provider,
    _ProviderStatusSnapshot status,
  ) {
    if (provider == AssistantProviderType.codex) {
      ref.read(codexInstalledProvider.notifier).state = status.installed;
      ref.read(codexAuthenticatedProvider.notifier).state =
          status.authenticated;
      ref.read(codexAuthLabelProvider.notifier).state = status.badgeLabel;
      return;
    }

    ref.read(copilotInstalledProvider.notifier).state = status.installed;
    ref.read(copilotAuthenticatedProvider.notifier).state =
        status.authenticated;
    ref.read(copilotAuthLabelProvider.notifier).state = status.badgeLabel;
  }

  Future<_ProviderStatusSnapshot> _syncProviderStatus(
    AssistantProviderType provider,
  ) async {
    final status = await _inspectProviderStatus(provider);
    _pushProviderStatus(provider, status);
    return status;
  }

  String _buildPrompt({
    required String text,
    required List<ChatMessage> history,
    required String projectRoot,
    required AssistantProviderType assistantProvider,
  }) {
    final activePath = _projectScopedPath(
      ref.read(activeFilePathProvider),
      projectRoot,
    );
    final inspectorSelection = _projectScopedInspectorSelection(
      ref.read(inspectorSelectionProvider),
      projectRoot,
    );
    final selectedSourcePath = _projectScopedPath(
      inspectorSelection?.sourceFile,
      projectRoot,
    );
    final selectedSourceExcerpt = selectedSourcePath == null
        ? null
        : _readFileExcerpt(
            selectedSourcePath,
            startLine: inspectorSelection?.line,
            endLine: inspectorSelection?.endLine,
          );
    final promptHistory = _recentPromptHistory(history);
    final systemBuffer = StringBuffer()
      ..writeln(
        'You are ${assistantProvider.label} running inside Flora, a Flutter desktop coding workspace.',
      )
      ..writeln('Work inside this project root: $projectRoot')
      ..writeln(
        'Treat the USER MESSAGE block as the only task to execute. All other blocks are supporting context.',
      )
      ..writeln(
        'Respond directly to the user request instead of acknowledging setup or restating instructions.',
      )
      ..writeln(
        'If the user asks for code or configuration changes, inspect and modify the relevant local files under the project root before answering.',
      )
      ..writeln(
        'Ignore Copilot-injected timestamps, environment notes, SQL reminders, and other boilerplate that are not part of the user task.',
      )
      ..writeln(
        'Never claim that no actionable task was provided when the Primary task field is non-empty.',
      )
      ..writeln(
        'If the Primary task uses words like this, that, it, selected, or here, resolve them against the selected Flutter Inspector widget and source excerpt when available.',
      )
      ..writeln(
        'When the requested change target is clear enough, make the local file edit instead of only describing what should change.',
      )
      ..writeln(
        'Ignore any file, inspector, or conversation context that falls outside this project root.',
      )
      ..writeln(
        'Answer concisely and use fenced code blocks when code is helpful.',
      );

    final userBuffer = StringBuffer()
      ..writeln('Primary task:')
      ..writeln(text.trim());

    if (inspectorSelection != null && _looksLikeDeicticTask(text)) {
      userBuffer
        ..writeln()
        ..writeln(
          'Task resolution: words like "this", "that", or "it" refer to the selected Flutter Inspector widget and its source excerpt below.',
        );
    }

    if (activePath != null) {
      userBuffer
        ..writeln()
        ..writeln('Active file: $activePath');
    }

    if (inspectorSelection != null) {
      final sourceFile = inspectorSelection.sourceFile;
      final sourceDirectory = sourceFile == null ? null : p.dirname(sourceFile);
      final startLine = inspectorSelection.line;
      final endLine = inspectorSelection.endLine;
      final sourceRange = startLine == null
          ? null
          : (endLine != null && endLine >= startLine)
          ? '$startLine-$endLine'
          : '$startLine';

      userBuffer
        ..writeln()
        ..writeln('Active Flutter Inspector selection:')
        ..writeln('- Widget: ${inspectorSelection.widgetName}')
        ..writeln('- Description: ${inspectorSelection.description}')
        ..writeln('- Source file: ${sourceFile ?? 'unknown file'}');

      if (sourceDirectory != null && sourceDirectory.trim().isNotEmpty) {
        userBuffer.writeln('- Source directory: $sourceDirectory');
      }

      if (startLine != null) {
        userBuffer.writeln('- Source line start: $startLine');
      }

      if (endLine != null) {
        userBuffer.writeln('- Source line end: $endLine');
      }

      if (sourceRange != null) {
        userBuffer.writeln('- Source line range: $sourceRange');
      }

      if (selectedSourceExcerpt != null && selectedSourceExcerpt.isNotEmpty) {
        userBuffer
          ..writeln()
          ..writeln('Selected widget source excerpt:')
          ..writeln('```dart')
          ..writeln(selectedSourceExcerpt)
          ..writeln('```');
      }
    }

    if (promptHistory.isNotEmpty) {
      userBuffer
        ..writeln()
        ..writeln('Recent conversation (most recent last):');
      for (final message in promptHistory) {
        final role = switch (message.role) {
          MessageRole.user => 'User',
          MessageRole.assistant => 'Assistant',
          MessageRole.system => 'System',
        };
        userBuffer
          ..writeln('$role:')
          ..writeln(_summarizeConversationEntry(message.content))
          ..writeln();
      }
    }

    final promptBuffer = StringBuffer()
      ..writeln('--- SYSTEM INSTRUCTIONS ---')
      ..writeln(systemBuffer.toString().trimRight())
      ..writeln('--- END SYSTEM INSTRUCTIONS ---')
      ..writeln()
      ..writeln('--- USER MESSAGE ---')
      ..writeln(userBuffer.toString().trimRight())
      ..writeln('--- END USER MESSAGE ---');

    return promptBuffer.toString();
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final recentDuplicate =
        _lastSubmittedText == text &&
        _lastSubmittedAt != null &&
        now.difference(_lastSubmittedAt!) < const Duration(seconds: 2);
    if (recentDuplicate) {
      return;
    }

    final projectRoot = ref.read(projectRootProvider);
    if (projectRoot == null || projectRoot.trim().isEmpty) {
      return;
    }

    _lastSubmittedText = text;
    _lastSubmittedAt = now;

    final selectedAssistant = ref.read(assistantProvider);
    final history = ref.read(chatHistoryProvider);
    final selectedModel = selectedAssistant == AssistantProviderType.codex
        ? ref.read(codexModelProvider)
        : ref.read(copilotModelProvider);
    final selectedReasoningEffort =
        selectedAssistant == AssistantProviderType.codex
        ? ref.read(codexReasoningEffortProvider)
        : ref.read(copilotReasoningEffortProvider);
    final selectedCopilotPermissionMode = ref.read(
      copilotPermissionModeProvider,
    );
    final inspectorSelection = _projectScopedInspectorSelection(
      ref.read(inspectorSelectionProvider),
      projectRoot,
    );
    final statusBeforeFuture = _inspectProviderStatus(selectedAssistant);
    final prompt = _buildPrompt(
      text: text,
      history: history,
      projectRoot: projectRoot,
      assistantProvider: selectedAssistant,
    );
    final assistantMessageId = '${DateTime.now().millisecondsSinceEpoch}_a';

    _inputCtrl.clear();

    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: MessageRole.user,
      content: text,
      timestamp: DateTime.now(),
      inspectorAttachment: inspectorSelection,
      model: selectedModel,
      reasoningEffort: selectedReasoningEffort,
      assistantProvider: selectedAssistant,
    );
    final streamingMsg = ChatMessage(
      id: assistantMessageId,
      role: MessageRole.assistant,
      content: 'Thinking…',
      timestamp: now,
      inspectorAttachment: inspectorSelection,
      model: selectedModel,
      reasoningEffort: selectedReasoningEffort,
      assistantProvider: selectedAssistant,
      thoughts: const [],
      debugLines: const [],
      isStreaming: true,
    );

    ref
        .read(chatHistoryProvider.notifier)
        .update((state) => [...state, userMsg, streamingMsg]);
    ref
        .read(chatActiveRequestCountProvider.notifier)
        .update((count) => count + 1);
    _scrollToBottom(force: true);

    try {
      final statusBefore = await statusBeforeFuture;
      _pushProviderStatus(selectedAssistant, statusBefore);

      final startedAt = DateTime.now();

      final result = selectedAssistant == AssistantProviderType.codex
          ? await CodexCliService.execPrompt(
              prompt: prompt,
              workingDirectory: projectRoot,
              model: selectedModel,
              reasoningEffort: selectedReasoningEffort,
              onProgress: (update) =>
                  _handleProgressUpdate(assistantMessageId, update),
            )
          : await CopilotCliService.execPrompt(
              prompt: prompt,
              workingDirectory: projectRoot,
              model: selectedModel,
              reasoningEffort: selectedReasoningEffort,
              permissionMode: selectedCopilotPermissionMode,
              onProgress: (update) =>
                  _handleProgressUpdate(assistantMessageId, update),
            );
      final durationMs = DateTime.now().difference(startedAt).inMilliseconds;

      _ProviderStatusSnapshot? statusAfter;

      if (!result.success) {
        statusAfter = await _syncProviderStatus(selectedAssistant);
      }

      final successOutput = result.stdout.trim();
      final content = result.success
          ? (successOutput.isEmpty
                ? '${selectedAssistant.label} returned no output.'
                : successOutput)
          : (result.combinedOutput.trim().isEmpty
                ? '${selectedAssistant.label} returned no output.'
                : result.combinedOutput);
      final completionMessage = result.completionMessage?.trim() ?? '';
      final completionStatus = result.success
          ? '${selectedAssistant.label} completed in ${durationMs}ms (exit ${result.exitCode ?? 0}).'
          : '${selectedAssistant.label} failed in ${durationMs}ms (exit ${result.exitCode ?? -1}).';
      final modificationSummary = result.modifiedFiles.isEmpty
          ? ''
          : '\nModified ${result.modifiedFiles.length} file(s) (${result.linesAdded}+, ${result.linesRemoved}-).';
      final completionSummary =
          completionMessage.isNotEmpty && completionMessage != content.trim()
          ? '$completionStatus$modificationSummary\n$completionMessage'
          : '$completionStatus$modificationSummary';

      // Key execution facts are placed first so they remain visible within the
      // 16-line monospace cap in _MessageMetaBlock.  Event timeline entries
      // follow immediately after so the execution log is always reachable.
      final debugLines = <String>[
        'exec.success ${result.success}',
        'exec.exit ${result.exitCode ?? -1}',
        'exec.duration_ms $durationMs',
        'provider ${selectedAssistant.key}',
        'exec.strategy ${result.executionStrategy}',
        if (selectedAssistant == AssistantProviderType.copilot)
          'exec.permissions ${selectedCopilotPermissionMode.key}',
        'exec.user_request ${_truncateDebug(text, 180)}',
        if (result.submittedPrimaryTask != null)
          'exec.primary_task ${_truncateDebug(result.submittedPrimaryTask!, 180)}',
        'exec.model $selectedModel',
        'exec.reasoning $selectedReasoningEffort',
        if (result.taskFilePath != null)
          'exec.task_file ${p.basename(result.taskFilePath!)}',
        'exec.modified_files ${result.modifiedFiles.length}',
        'exec.diff_stats added=${result.linesAdded} removed=${result.linesRemoved}',
        ...result.modifiedFiles.take(4).map((file) => 'exec.file $file'),
        if (result.stderr.trim().isNotEmpty)
          'exec.stderr ${result.stderr.trim()}',
        ...result.eventTimeline.map((event) => 'event $event'),
        'connection.before installed=${statusBefore.installed} authenticated=${statusBefore.authenticated} mode=${statusBefore.mode}',
        'connection.before.label ${statusBefore.badgeLabel}',
        'exec.prompt_history_users ${promptHistoryCount(history)}',
        'exec.cwd $projectRoot',
        if (result.commandLine.trim().isNotEmpty)
          'exec.command ${result.commandLine}',
        if (statusAfter != null)
          'connection.after installed=${statusAfter.installed} authenticated=${statusAfter.authenticated} mode=${statusAfter.mode} label=${statusAfter.badgeLabel}',
      ];

      final assistantMsg = ChatMessage(
        id: assistantMessageId,
        role: MessageRole.assistant,
        content: content,
        timestamp: DateTime.now(),
        inspectorAttachment: inspectorSelection,
        model: selectedModel,
        reasoningEffort: selectedReasoningEffort,
        assistantProvider: selectedAssistant,
        completionSummary: completionSummary,
        debugLines: debugLines.take(40).toList(),
        thoughts: result.modelThoughts,
        isStreaming: false,
      );
      _replaceChatMessage(assistantMessageId, (_) => assistantMsg);

      if (result.success) {
        ref
            .read(hotReloadTriggerProvider.notifier)
            .update((count) => count + 1);
      }
    } catch (error) {
      final assistantMsg = ChatMessage(
        id: assistantMessageId,
        role: MessageRole.assistant,
        content: '${selectedAssistant.label} request failed: $error',
        timestamp: DateTime.now(),
        inspectorAttachment: inspectorSelection,
        model: selectedModel,
        reasoningEffort: selectedReasoningEffort,
        assistantProvider: selectedAssistant,
        completionSummary:
            '${selectedAssistant.label} execution failed before completion.',
        debugLines: ['exception $error'],
        thoughts: const [],
        isStreaming: false,
      );
      _replaceChatMessage(assistantMessageId, (_) => assistantMsg);
    } finally {
      ref
          .read(chatActiveRequestCountProvider.notifier)
          .update((count) => count > 0 ? count - 1 : 0);
      _scrollToBottom(force: true);
    }
  }

  void _replaceChatMessage(
    String id,
    ChatMessage Function(ChatMessage message) transform,
  ) {
    final history = ref.read(chatHistoryProvider);
    final index = history.indexWhere((message) => message.id == id);
    if (index == -1) {
      return;
    }

    final updated = [...history];
    updated[index] = transform(updated[index]);
    ref.read(chatHistoryProvider.notifier).state = updated;
  }

  void _handleProgressUpdate(
    String assistantMessageId,
    AssistantExecutionUpdate update,
  ) {
    if (!mounted) {
      return;
    }

    _replaceChatMessage(
      assistantMessageId,
      (message) => message.copyWith(
        content: update.streamedContent?.trim().isNotEmpty == true
            ? update.streamedContent!
            : update.status,
        thoughts: update.thoughts,
        debugLines: update.events,
        isStreaming: !update.isFinal,
      ),
    );
    _scrollToBottom();
  }

  void _scrollToBottom({bool force = false}) {
    _pendingScroll?.cancel();
    _pendingScroll = Timer(
      force ? Duration.zero : const Duration(milliseconds: 70),
      () {
        if (!mounted) {
          return;
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollCtrl.hasClients) {
            return;
          }

          final position = _scrollCtrl.position;
          final distanceToBottom = position.maxScrollExtent - position.pixels;
          if (!force && distanceToBottom > 180) {
            return;
          }

          _scrollCtrl.animateTo(
            position.maxScrollExtent,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
          );
        });
      },
    );
  }

  int promptHistoryCount(List<ChatMessage> history) {
    return _recentPromptHistory(history).length;
  }

  String _truncateDebug(String value, int maxChars) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxChars) {
      return normalized;
    }
    return '${normalized.substring(0, maxChars)}...';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(chatComposerTextProvider, (previous, next) {
      if (_inputCtrl.text == next) {
        return;
      }

      _inputCtrl.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    });

    final selectedAssistant = ref.watch(assistantProvider);
    final usingCodex = selectedAssistant == AssistantProviderType.codex;
    final providerInstalled = usingCodex
        ? ref.watch(codexInstalledProvider)
        : ref.watch(copilotInstalledProvider);
    final providerAuthenticated = usingCodex
        ? ref.watch(codexAuthenticatedProvider)
        : ref.watch(copilotAuthenticatedProvider);
    final projectRoot = ref.watch(projectRootProvider);

    return Container(
      color: FloraPalette.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PaneHeader(label: '${selectedAssistant.label.toUpperCase()} CHAT'),
          const Divider(height: 1),
          Expanded(
            child: !providerInstalled || !providerAuthenticated
                ? _ProviderGate(
                    provider: selectedAssistant,
                    installed: providerInstalled,
                    authenticated: providerAuthenticated,
                  )
                : (projectRoot == null || projectRoot.trim().isEmpty)
                ? const _ProjectGate()
                : _ChatBody(
                    scrollCtrl: _scrollCtrl,
                    inputCtrl: _inputCtrl,
                    inputFocus: _inputFocus,
                    onSend: _send,
                  ),
          ),
        ],
      ),
    );
  }
}

class _ProviderGate extends ConsumerWidget {
  const _ProviderGate({
    required this.provider,
    required this.installed,
    required this.authenticated,
  });

  final AssistantProviderType provider;
  final bool installed;
  final bool authenticated;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = provider == AssistantProviderType.codex
        ? ref.watch(codexAuthLabelProvider)
        : ref.watch(copilotAuthLabelProvider);
    final providerLabel = provider.label;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              installed ? Icons.lock_outline : Icons.terminal,
              size: 28,
              color: FloraPalette.textDimmed,
            ),
            const SizedBox(height: 12),
            Text(
              installed
                  ? 'Sign in to $providerLabel CLI'
                  : '$providerLabel CLI required',
              style: const TextStyle(
                color: FloraPalette.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              authenticated
                  ? label
                  : provider == AssistantProviderType.codex
                  ? 'Open Settings to install Codex CLI and sign in with ChatGPT.'
                  : 'Open Settings to install GitHub Copilot CLI and sign in with GitHub.',
              style: const TextStyle(
                color: FloraPalette.textDimmed,
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectGate extends StatelessWidget {
  const _ProjectGate();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_outlined,
              size: 28,
              color: FloraPalette.textDimmed,
            ),
            SizedBox(height: 12),
            Text(
              'No project folder selected',
              style: TextStyle(
                color: FloraPalette.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Open a project folder from Settings or the Explorer pane before starting chat.',
              style: TextStyle(color: FloraPalette.textDimmed, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatBody extends ConsumerWidget {
  const _ChatBody({
    required this.scrollCtrl,
    required this.inputCtrl,
    required this.inputFocus,
    required this.onSend,
  });

  final ScrollController scrollCtrl;
  final TextEditingController inputCtrl;
  final FocusNode inputFocus;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(chatHistoryProvider);
    final active = ref.watch(activeFilePathProvider);
    final root = ref.watch(projectRootProvider);
    final inspectorSelection = ref.watch(inspectorSelectionProvider);
    final scopedActive = _projectScopedPath(active, root);
    final scopedInspectorSelection = _projectScopedInspectorSelection(
      inspectorSelection,
      root,
    );
    final interactionMode = ref.watch(previewInteractionModeProvider);
    final activeRequestCount = ref.watch(chatActiveRequestCountProvider);
    final selectedAssistant = ref.watch(assistantProvider);
    final usingCodex = selectedAssistant == AssistantProviderType.codex;
    final selectedModel = usingCodex
        ? ref.watch(codexModelProvider)
        : ref.watch(copilotModelProvider);
    final selectedReasoningEffort = usingCodex
        ? ref.watch(codexReasoningEffortProvider)
        : ref.watch(copilotReasoningEffortProvider);
    final modelOptions = usingCodex
        ? _chatCodexModelOptions
        : _chatCopilotModelOptions;

    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: messages.isEmpty
                  ? Padding(
                      padding: EdgeInsets.only(top: 76),
                      child: _EmptyChat(providerLabel: selectedAssistant.label),
                    )
                  : ListView.builder(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(8, 76, 8, 8),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        return _MessageTile(message: messages[index]);
                      },
                    ),
            ),
            const Divider(height: 1),
            _InputBar(
              ctrl: inputCtrl,
              focus: inputFocus,
              onSend: onSend,
              placeholder: 'Ask ${selectedAssistant.label}...',
            ),
          ],
        ),
        Positioned(
          top: 8,
          left: 10,
          right: 10,
          child: _ChatContextFloater(
            projectRoot: root,
            activeFilePath: scopedActive,
            inspectorLabel: scopedInspectorSelection == null
                ? null
                : _formatInspectorSelectionLabel(scopedInspectorSelection),
            interactionMode: interactionMode,
            activeRequestCount: activeRequestCount,
            assistantProvider: selectedAssistant,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            modelOptions: modelOptions,
            onClearActiveFile: scopedActive == null
                ? null
                : () => ref.read(activeFilePathProvider.notifier).state = null,
            onClearInspector: scopedInspectorSelection == null
                ? null
                : () => ref.read(inspectorSelectionProvider.notifier).state =
                      null,
            onModelChanged: (newModel) async {
              if (newModel == selectedModel) return;
              final prefs = await SharedPreferences.getInstance();
              if (selectedAssistant == AssistantProviderType.codex) {
                await prefs.setString('codex_model', newModel);
                ref.read(codexModelProvider.notifier).state = newModel;
              } else {
                await prefs.setString('copilot_model', newModel);
                ref.read(copilotModelProvider.notifier).state = newModel;
              }
            },
          ),
        ),
      ],
    );
  }

  String _formatInspectorSelectionLabel(InspectorSelectionContext selection) {
    final fileName = selection.sourceFile == null
        ? null
        : p.basename(selection.sourceFile!);
    final startLine = selection.line;
    final endLine = selection.endLine;
    final locationLabel = fileName == null
        ? 'no source location'
        : startLine == null
        ? fileName
        : (endLine != null && endLine >= startLine)
        ? '$fileName:$startLine-$endLine'
        : '$fileName:$startLine';
    return 'Selected ${selection.widgetName} ($locationLabel)';
  }
}

class _ChatContextFloater extends StatelessWidget {
  const _ChatContextFloater({
    required this.projectRoot,
    required this.activeFilePath,
    required this.inspectorLabel,
    required this.interactionMode,
    required this.activeRequestCount,
    required this.assistantProvider,
    required this.model,
    required this.reasoningEffort,
    required this.modelOptions,
    required this.onClearActiveFile,
    required this.onClearInspector,
    required this.onModelChanged,
  });

  final String? projectRoot;
  final String? activeFilePath;
  final String? inspectorLabel;
  final PreviewInteractionMode interactionMode;
  final int activeRequestCount;
  final AssistantProviderType assistantProvider;
  final String model;
  final String reasoningEffort;
  final List<String> modelOptions;
  final VoidCallback? onClearActiveFile;
  final VoidCallback? onClearInspector;
  final ValueChanged<String> onModelChanged;

  @override
  Widget build(BuildContext context) {
    final projectLabel = projectRoot == null
        ? 'No project selected'
        : p.basename(projectRoot!);
    final fileLabel = activeFilePath == null
        ? 'No active file'
        : activeFilePath!.split(RegExp(r'[/\\]')).last;

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: FloraPalette.panelBg.withValues(alpha: 0.96),
          border: Border.all(color: FloraPalette.border),
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.layers_outlined,
                  size: 13,
                  color: FloraPalette.textSecondary,
                ),
                const SizedBox(width: 6),
                const Text(
                  'Context',
                  style: TextStyle(
                    color: FloraPalette.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 2,
                      children: [
                        PopupMenuButton<String>(
                          tooltip: 'Change Model',
                          initialValue: model,
                          onSelected: onModelChanged,
                          offset: const Offset(0, 24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: FloraPalette.border),
                          ),
                          color: FloraPalette.panelBg,
                          itemBuilder: (context) {
                            return modelOptions.map((m) {
                              return PopupMenuItem<String>(
                                value: m,
                                height: 32,
                                child: Text(
                                  m,
                                  style: FloraTheme.mono(
                                    size: 11,
                                    color: m == model
                                        ? FloraPalette.textPrimary
                                        : FloraPalette.textDimmed,
                                  ),
                                ),
                              );
                            }).toList();
                          },
                          child: Text(
                            'model: $model',
                            style: FloraTheme.mono(
                              size: 10,
                              color: FloraPalette.textSecondary,
                            ).copyWith(decoration: TextDecoration.underline),
                          ),
                        ),
                        Text(
                          'provider: ${assistantProvider.label}',
                          style: FloraTheme.mono(
                            size: 10,
                            color: FloraPalette.textSecondary,
                          ),
                        ),
                        Text(
                          'reasoning: $reasoningEffort',
                          style: FloraTheme.mono(
                            size: 10,
                            color: FloraPalette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _ContextPill(
                  icon: Icons.workspaces_outline,
                  text: projectLabel,
                ),
                _ContextPill(
                  icon: interactionMode == PreviewInteractionMode.annotate
                      ? Icons.ads_click_outlined
                      : Icons.touch_app_outlined,
                  text: interactionMode.label,
                ),
                if (activeRequestCount > 0)
                  _ContextPill(
                    icon: Icons.sync_outlined,
                    text:
                        '$activeRequestCount run${activeRequestCount == 1 ? '' : 's'} active',
                  ),
                _ContextPill(
                  icon: Icons.insert_drive_file_outlined,
                  text: fileLabel,
                  onClear: onClearActiveFile,
                ),
                if (inspectorLabel != null)
                  _ContextPill(
                    icon: Icons.ads_click_outlined,
                    text: inspectorLabel!,
                    onClear: onClearInspector,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ContextPill extends StatelessWidget {
  const _ContextPill({required this.icon, required this.text, this.onClear});

  final IconData icon;
  final String text;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: FloraPalette.background,
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
          if (onClear != null) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: onClear,
              child: const Icon(
                Icons.close,
                size: 12,
                color: FloraPalette.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.providerLabel});

  final String providerLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            providerLabel,
            style: const TextStyle(
              color: FloraPalette.textDimmed,
              fontSize: 22,
              fontWeight: FontWeight.w300,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Ask anything about the selected Flutter project. You can keep sending requests while earlier runs finish.',
            style: TextStyle(color: FloraPalette.textDimmed, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final debugTitle =
        '${message.assistantProvider?.label ?? 'Assistant'} debug';
    final bubbleRadius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(isUser ? 18 : 6),
      bottomRight: Radius.circular(isUser ? 6 : 18),
    );
    final showCompletion =
        message.completionSummary != null &&
        message.completionSummary!.trim().isNotEmpty;
    final showThoughts = message.thoughts.isNotEmpty;
    final showDebug = message.debugLines.isNotEmpty && !message.isStreaming;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        margin: EdgeInsets.only(
          left: isUser ? 40 : 10,
          right: isUser ? 10 : 40,
          top: 4,
          bottom: 4,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isUser ? FloraPalette.selectedBg : FloraPalette.panelBg,
          border: Border.all(color: FloraPalette.border),
          borderRadius: bubbleRadius,
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.isStreaming) ...[
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: FloraPalette.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Thinking live',
                    style: TextStyle(
                      color: FloraPalette.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            _buildContent(message.content),
            if (message.inspectorAttachment != null) ...[
              const SizedBox(height: 8),
              _MessageInspectorAttachment(
                selection: message.inspectorAttachment!,
              ),
            ],
            if (showThoughts) ...[
              const SizedBox(height: 8),
              _MessageMetaBlock(
                icon: Icons.psychology_alt_outlined,
                title: message.isStreaming
                    ? 'Live thoughts'
                    : 'Condensed thoughts',
                lines: message.thoughts,
              ),
            ],
            if (showCompletion) ...[
              const SizedBox(height: 8),
              _MessageMetaBlock(
                icon: Icons.task_alt_outlined,
                title: 'Completion',
                lines: [message.completionSummary!.trim()],
              ),
            ],
            if (showDebug) ...[
              const SizedBox(height: 8),
              _MessageMetaBlock(
                icon: Icons.bug_report_outlined,
                title: debugTitle,
                lines: message.debugLines,
                monospace: true,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildContent(String content) {
    final blockPattern = RegExp(r'```([\w+-]*)\n([\s\S]*?)```');
    final matches = blockPattern.allMatches(content).toList();
    if (matches.isEmpty) {
      return Text(content, style: _messageTextStyle());
    }

    final children = <Widget>[];
    var cursor = 0;

    for (final match in matches) {
      final leading = content.substring(cursor, match.start).trim();
      if (leading.isNotEmpty) {
        if (children.isNotEmpty) {
          children.add(const SizedBox(height: 8));
        }
        children.add(Text(leading, style: _messageTextStyle()));
      }

      final code = (match.group(2) ?? '').trimRight();
      if (code.isNotEmpty) {
        if (children.isNotEmpty) {
          children.add(const SizedBox(height: 8));
        }
        children.add(
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: FloraPalette.background,
              border: Border.all(color: FloraPalette.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(code, style: FloraTheme.mono(size: 11)),
          ),
        );
      }

      cursor = match.end;
    }

    final tail = content.substring(cursor).trim();
    if (tail.isNotEmpty) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: 8));
      }
      children.add(Text(tail, style: _messageTextStyle()));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  TextStyle _messageTextStyle() {
    final isUser = message.role == MessageRole.user;
    return TextStyle(
      color: isUser ? Colors.white : FloraPalette.textPrimary,
      fontSize: 13,
      height: 1.5,
    );
  }
}

class _MessageInspectorAttachment extends StatelessWidget {
  const _MessageInspectorAttachment({required this.selection});

  final InspectorSelectionContext selection;

  @override
  Widget build(BuildContext context) {
    final sourceLabel = selection.sourceFile == null
        ? 'unknown source'
        : p.basename(selection.sourceFile!);
    final startLine = selection.line;
    final endLine = selection.endLine;
    final locationLabel = startLine == null
        ? sourceLabel
        : (endLine != null && endLine >= startLine)
        ? '$sourceLabel:$startLine-$endLine'
        : '$sourceLabel:$startLine';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: FloraPalette.background.withValues(alpha: 0.72),
        border: Border.all(color: FloraPalette.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.ads_click_outlined,
                size: 12,
                color: FloraPalette.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                selection.widgetName,
                style: const TextStyle(
                  color: FloraPalette.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                locationLabel,
                style: FloraTheme.mono(
                  size: 10,
                  color: FloraPalette.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            selection.description,
            style: const TextStyle(
              color: FloraPalette.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageMetaBlock extends StatelessWidget {
  const _MessageMetaBlock({
    required this.icon,
    required this.title,
    required this.lines,
    this.monospace = false,
  });

  final IconData icon;
  final String title;
  final List<String> lines;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final maxVisibleLines = monospace ? 16 : 12;
    final visibleLines = lines
        .where((line) => line.trim().isNotEmpty)
        .take(maxVisibleLines)
        .toList(growable: true);

    if (lines.length > visibleLines.length) {
      visibleLines.add('... ${lines.length - visibleLines.length} more lines');
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: FloraPalette.background.withValues(alpha: 0.72),
        border: Border.all(color: FloraPalette.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: FloraPalette.textSecondary),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  color: FloraPalette.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final line in visibleLines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                line,
                style: monospace
                    ? FloraTheme.mono(
                        size: 10,
                        color: FloraPalette.textSecondary,
                      )
                    : const TextStyle(
                        color: FloraPalette.textPrimary,
                        fontSize: 11,
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InputBar extends ConsumerWidget {
  const _InputBar({
    required this.ctrl,
    required this.focus,
    required this.onSend,
    required this.placeholder,
  });

  final TextEditingController ctrl;
  final FocusNode focus;
  final VoidCallback onSend;
  final String placeholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeRequests = ref.watch(chatActiveRequestCountProvider);

    return Container(
      color: FloraPalette.panelBg,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (activeRequests > 0)
            Padding(
              padding: const EdgeInsets.only(right: 2, bottom: 6),
              child: Text(
                '$activeRequests run${activeRequests == 1 ? '' : 's'} active. Send another request or keep editing the draft.',
                style: const TextStyle(
                  color: FloraPalette.textSecondary,
                  fontSize: 10,
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  focusNode: focus,
                  maxLines: 5,
                  minLines: 1,
                  style: const TextStyle(
                    color: FloraPalette.textPrimary,
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    hintText: placeholder,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: (_) => onSend(),
                  textInputAction: TextInputAction.send,
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: onSend,
                borderRadius: BorderRadius.circular(2),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: FloraPalette.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const Icon(Icons.send, size: 14, color: Colors.white),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      color: FloraPalette.sidebarBg,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: const TextStyle(
            color: FloraPalette.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }
}
