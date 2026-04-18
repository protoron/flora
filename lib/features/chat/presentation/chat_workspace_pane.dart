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

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  String? _readActiveFile() {
    final path = ref.read(activeFilePathProvider);
    if (path == null) {
      return null;
    }

    try {
      return File(path).readAsStringSync();
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
    final activePath = ref.read(activeFilePathProvider);
    final fileContent = _readActiveFile();
    final inspectorSelection = ref.read(inspectorSelectionProvider);
    final buffer = StringBuffer()
      ..writeln(
        'You are ${assistantProvider.label} inside Flora, a Flutter desktop coding workspace.',
      )
      ..writeln('Work inside this project root: $projectRoot')
      ..writeln(
        'Answer concisely and use fenced code blocks when code is helpful.',
      )
      ..writeln();

    if (activePath != null) {
      buffer.writeln('Active file: $activePath');
      if (fileContent != null) {
        final snippet = fileContent.split('\n').take(400).join('\n');
        buffer
          ..writeln()
          ..writeln('Open file contents:')
          ..writeln('```')
          ..writeln(snippet)
          ..writeln('```');
      }
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

      buffer
        ..writeln()
        ..writeln('Active Flutter Inspector selection:')
        ..writeln('- Widget: ${inspectorSelection.widgetName}')
        ..writeln('- Description: ${inspectorSelection.description}')
        ..writeln('- Source file: ${sourceFile ?? 'unknown file'}');

      if (sourceDirectory != null && sourceDirectory.trim().isNotEmpty) {
        buffer.writeln('- Source directory: $sourceDirectory');
      }

      if (startLine != null) {
        buffer.writeln('- Source line start: $startLine');
      }

      if (endLine != null) {
        buffer.writeln('- Source line end: $endLine');
      }

      if (sourceRange != null) {
        buffer.writeln('- Source line range: $sourceRange');
      }

      if (inspectorSelection.ancestorPath.isNotEmpty) {
        buffer.writeln(
          '- Ancestor path: ${inspectorSelection.ancestorPath.join(' > ')}',
        );
      }
    }

    if (history.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Recent conversation:');
      for (final message in history.take(8)) {
        final role = switch (message.role) {
          MessageRole.user => 'User',
          MessageRole.assistant => 'Assistant',
          MessageRole.system => 'System',
        };
        buffer
          ..writeln('$role:')
          ..writeln(message.content.trim())
          ..writeln();
      }
    }

    buffer
      ..writeln('Current user request:')
      ..writeln(text);

    return buffer.toString();
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) {
      return;
    }

    final projectRoot = ref.read(projectRootProvider);
    if (projectRoot == null || projectRoot.trim().isEmpty) {
      return;
    }

    final selectedAssistant = ref.read(assistantProvider);
    final history = ref.read(chatHistoryProvider);
    final selectedModel = selectedAssistant == AssistantProviderType.codex
        ? ref.read(codexModelProvider)
        : ref.read(copilotModelProvider);
    final selectedReasoningEffort =
        selectedAssistant == AssistantProviderType.codex
        ? ref.read(codexReasoningEffortProvider)
        : ref.read(copilotReasoningEffortProvider);
    final inspectorSelection = ref.read(inspectorSelectionProvider);
    final statusBeforeFuture = _inspectProviderStatus(selectedAssistant);
    final prompt = _buildPrompt(
      text: text,
      history: history,
      projectRoot: projectRoot,
      assistantProvider: selectedAssistant,
    );
    final assistantMessageId = '${DateTime.now().millisecondsSinceEpoch}_a';
    final now = DateTime.now();

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
    ref.read(chatLoadingProvider.notifier).state = true;
    _scrollToBottom();

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
      final completionSummary =
          completionMessage.isNotEmpty && completionMessage != content.trim()
          ? '$completionStatus\n$completionMessage'
          : completionStatus;

      final debugLines = <String>[
        'provider ${selectedAssistant.key}',
        'connection.before installed=${statusBefore.installed} authenticated=${statusBefore.authenticated} mode=${statusBefore.mode}',
        'connection.before.label ${statusBefore.badgeLabel}',
        'exec.model $selectedModel',
        'exec.reasoning $selectedReasoningEffort',
        if (result.commandLine.trim().isNotEmpty)
          'exec.command ${result.commandLine}',
        'exec.cwd $projectRoot',
        'exec.success ${result.success}',
        'exec.exit ${result.exitCode ?? -1}',
        'exec.duration_ms $durationMs',
        if (result.stderr.trim().isNotEmpty)
          'exec.stderr ${result.stderr.trim()}',
        ...result.eventTimeline.map((event) => 'event $event'),
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
        debugLines: debugLines.take(24).toList(),
        thoughts: result.modelThoughts,
        isStreaming: false,
      );
      _replaceChatMessage(assistantMessageId, (_) => assistantMsg);

      // Trigger hot reload after every completed Codex message.
      ref.read(hotReloadTriggerProvider.notifier).update((count) => count + 1);
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
      ref.read(chatLoadingProvider.notifier).state = false;
      _scrollToBottom();
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
        content: update.status,
        thoughts: update.thoughts,
        debugLines: update.events,
        isStreaming: !update.isFinal,
      ),
    );
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
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
            activeFilePath: active,
            inspectorLabel: inspectorSelection == null
                ? null
                : _formatInspectorSelectionLabel(inspectorSelection),
            assistantProvider: selectedAssistant,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            modelOptions: modelOptions,
            onClearActiveFile: active == null
                ? null
                : () => ref.read(activeFilePathProvider.notifier).state = null,
            onClearInspector: inspectorSelection == null
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
              ref.read(chatHistoryProvider.notifier).state = const [];
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
            'Ask anything about the selected Flutter project.',
            style: TextStyle(color: FloraPalette.textDimmed, fontSize: 12),
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
    final lineage = selection.ancestorPath.isEmpty
        ? null
        : selection.ancestorPath.take(4).join(' > ');

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
          if (lineage != null) ...[
            const SizedBox(height: 4),
            Text(
              lineage,
              style: FloraTheme.mono(size: 10, color: FloraPalette.textDimmed),
            ),
          ],
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
    final visibleLines = lines
        .where((line) => line.trim().isNotEmpty)
        .take(12)
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
    final loading = ref.watch(chatLoadingProvider);

    return Container(
      color: FloraPalette.panelBg,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: ctrl,
              focusNode: focus,
              enabled: !loading,
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
            onTap: loading ? null : onSend,
            borderRadius: BorderRadius.circular(2),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: loading ? FloraPalette.border : FloraPalette.accent,
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Icon(Icons.send, size: 14, color: Colors.white),
            ),
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
