import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/flora_models.dart';
import 'codex_cli_service.dart';

enum CopilotAuthMode { missing, loggedOut, github, unknown }

class CopilotCliStatus {
  const CopilotCliStatus({
    required this.installed,
    required this.mode,
    required this.message,
  });

  final bool installed;
  final CopilotAuthMode mode;
  final String message;

  bool get authenticated => mode == CopilotAuthMode.github;

  String get badgeLabel {
    switch (mode) {
      case CopilotAuthMode.github:
        return 'Copilot GitHub';
      case CopilotAuthMode.loggedOut:
        return 'Copilot signed out';
      case CopilotAuthMode.unknown:
        return 'Copilot unknown';
      case CopilotAuthMode.missing:
        return 'Copilot missing';
    }
  }
}

class CopilotCliService {
  const CopilotCliService._();

  static const Duration _statusCacheTtl = Duration(seconds: 8);
  static CopilotCliStatus? _cachedStatus;
  static DateTime? _cachedStatusAt;
  static Future<CopilotCliStatus>? _statusProbe;

  static Future<CopilotCliStatus> inspectStatus({bool forceRefresh = false}) {
    final now = DateTime.now();
    if (!forceRefresh &&
        _cachedStatus != null &&
        _cachedStatusAt != null &&
        now.difference(_cachedStatusAt!) <= _statusCacheTtl) {
      return Future.value(_cachedStatus!);
    }

    if (!forceRefresh && _statusProbe != null) {
      return _statusProbe!;
    }

    final probe = _inspectStatusUncached();
    _statusProbe = probe
        .then((status) {
          _cachedStatus = status;
          _cachedStatusAt = DateTime.now();
          return status;
        })
        .whenComplete(() {
          _statusProbe = null;
        });
    return _statusProbe!;
  }

  static void invalidateStatusCache() {
    _cachedStatus = null;
    _cachedStatusAt = null;
  }

  static Future<CopilotCliStatus> _inspectStatusUncached() async {
    try {
      final directVersion = await Process.run('copilot', const [
        '--version',
      ], runInShell: true);
      final directText = _combineProcessOutput(directVersion).trim();
      final directLower = directText.toLowerCase();

      var installed = directVersion.exitCode == 0;
      var statusText = directText;

      if (!installed ||
          directLower.contains('cannot find github copilot cli')) {
        final ghProbe = await Process.run('gh', const [
          'copilot',
          '--',
          '--version',
        ], runInShell: true);
        final ghText = _combineProcessOutput(ghProbe).trim();
        final ghLower = ghText.toLowerCase();

        installed =
            ghProbe.exitCode == 0 &&
            !ghLower.contains('cannot find github copilot cli');
        statusText = ghText.ifEmpty(
          statusText.ifEmpty('Copilot CLI not found.'),
        );
      }

      if (!installed) {
        return CopilotCliStatus(
          installed: false,
          mode: CopilotAuthMode.missing,
          message: statusText.ifEmpty(
            'GitHub Copilot CLI is not installed. Run gh copilot once to install it.',
          ),
        );
      }

      final auth = await Process.run('gh', const [
        'auth',
        'status',
      ], runInShell: true);
      final authText = _combineProcessOutput(auth).trim();
      final authLower = authText.toLowerCase();

      if (auth.exitCode == 0) {
        return CopilotCliStatus(
          installed: true,
          mode: CopilotAuthMode.github,
          message: authText.ifEmpty('Authenticated with GitHub CLI.'),
        );
      }

      if (authLower.contains('not logged') ||
          authLower.contains('run: gh auth login')) {
        return CopilotCliStatus(
          installed: true,
          mode: CopilotAuthMode.loggedOut,
          message: authText.ifEmpty(
            'Run gh auth login to sign in with GitHub.',
          ),
        );
      }

      return CopilotCliStatus(
        installed: true,
        mode: CopilotAuthMode.unknown,
        message: authText.ifEmpty(
          statusText.ifEmpty('Copilot CLI is installed.'),
        ),
      );
    } on ProcessException catch (error) {
      return CopilotCliStatus(
        installed: false,
        mode: CopilotAuthMode.missing,
        message: error.message,
      );
    }
  }

  static Future<CodexCliCommandResult> install() async {
    final result = await _run('gh', const ['copilot', '--', '--version']);
    if (result.success) {
      return result;
    }

    final output = result.combinedOutput.toLowerCase();
    if (output.contains('cannot find github copilot cli')) {
      return const CodexCliCommandResult(
        success: false,
        exitCode: 1,
        stdout: '',
        stderr:
            'Copilot CLI installation requires interactive confirmation. Run gh copilot in a terminal once, approve installation, then retry.',
      );
    }

    if (result.success) {
      invalidateStatusCache();
    }
    return result;
  }

  static Future<CodexCliCommandResult> login({
    void Function(String detail)? onProgress,
  }) async {
    const arguments = [
      'auth',
      'login',
      '--web',
      '--clipboard',
      '--git-protocol',
      'https',
      '--skip-ssh-key',
    ];

    try {
      final process = await Process.start('gh', arguments, runInShell: true);
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final visibleLines = <String>[];
      String? deviceCode;

      void emitDetail(String line) {
        final trimmed = _stripAnsi(line).trim();
        if (trimmed.isEmpty) {
          return;
        }

        visibleLines.add(trimmed);
        deviceCode ??= _extractDeviceCode(trimmed);
        onProgress?.call(_buildLoginProgress(visibleLines, deviceCode));
      }

      onProgress?.call(_buildLoginProgress(const [], null));

      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stdoutBuffer.writeln(line);
            emitDetail(line);
          })
          .asFuture<void>();
      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stderrBuffer.writeln(line);
            emitDetail(line);
          })
          .asFuture<void>();

      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);

      return CodexCliCommandResult(
        success: exitCode == 0,
        exitCode: exitCode,
        stdout: stdoutBuffer.toString(),
        stderr: stderrBuffer.toString(),
        commandLine:
            'gh auth login --web --clipboard --git-protocol https --skip-ssh-key',
      );
    } on ProcessException catch (error) {
      return CodexCliCommandResult(
        success: false,
        exitCode: null,
        stdout: '',
        stderr: error.message,
      );
    } finally {
      invalidateStatusCache();
    }
  }

  static Future<CodexCliCommandResult> logout() {
    return Future.value(
      const CodexCliCommandResult(
        success: false,
        exitCode: 1,
        stdout: '',
        stderr:
            'Copilot CLI does not expose a dedicated logout command. Use gh auth logout if you want to sign out of GitHub CLI.',
      ),
    );
  }

  static String commandPreview({
    required String model,
    required String reasoningEffort,
    required CopilotPermissionMode permissionMode,
  }) {
    final arguments = [
      '-p',
      '<flora_compact_task_prompt_with_@brief>',
      '--add-dir',
      '<project root>',
      '--add-dir',
      '<temp task dir>',
      '--no-custom-instructions',
      ..._permissionArguments(permissionMode),
      '--stream',
      'on',
      '--output-format',
      'json',
      '--model',
      model.trim().isEmpty ? 'gpt-5.2' : model.trim(),
      '--reasoning-effort',
      _normalizeReasoningEffort(reasoningEffort),
    ];
    return _formatCommandLine(arguments);
  }

  static Future<CodexCliCommandResult> execPrompt({
    required String prompt,
    required String workingDirectory,
    String model = 'gpt-5.2',
    String reasoningEffort = 'medium',
    CopilotPermissionMode permissionMode = CopilotPermissionMode.workspaceWrite,
    void Function(AssistantExecutionUpdate update)? onProgress,
  }) async {
    Directory? tempDir;
    final normalizedModel = model.trim().isEmpty ? 'gpt-5.2' : model.trim();
    final normalizedReasoningEffort = _normalizeReasoningEffort(
      reasoningEffort,
    );

    try {
      tempDir = await Directory.systemTemp.createTemp('flora_copilot_');
      final taskFilePath = p.join(tempDir.path, 'flora_task.md');
      final taskFile = File(taskFilePath);
      final compactTaskBrief = _buildCompactTaskBrief(prompt);
      await taskFile.writeAsString(compactTaskBrief);

      final submittedPrimaryTask = _extractPrimaryTask(prompt);
      // Normalize path separators because prompt-mode @file mentions and tool
      // path parsing are more reliable with forward slashes on Windows.
      final driverTaskPath = taskFilePath.replaceAll('\\', '/');
      final driverWorkingDirectory = workingDirectory.replaceAll('\\', '/');
      final driverPrompt = StringBuffer()
        ..writeln(
          'Read @$driverTaskPath and execute the Primary task from that attached file.',
        )
        ..writeln('Treat that file as the source of truth for the task.')
        ..writeln('Work only inside this project root: $driverWorkingDirectory')
        ..writeln(
          'Modify local files if needed instead of only describing the change.',
        )
        ..writeln(
          'Prefer create/edit file tools for local changes before using shell commands.',
        )
        ..writeln('Return a concise summary of the result when finished.');

      final permissionArguments = _permissionArguments(permissionMode);

      final arguments = [
        '-p',
        driverPrompt.toString().trimRight(),
        '--add-dir',
        workingDirectory,
        '--add-dir',
        tempDir.path,
        '--no-custom-instructions',
        ...permissionArguments,
        '--stream',
        'on',
        '--output-format',
        'json',
        '--model',
        normalizedModel,
        '--reasoning-effort',
        normalizedReasoningEffort,
      ];

      final process = await Process.start(
        'copilot',
        arguments,
        workingDirectory: workingDirectory,
        runInShell: true,
      );

      final commandLine = _formatCommandLine(arguments);
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final eventTimeline = <String>[
        'prompt.original chars=${prompt.length}',
        'task_brief chars=${compactTaskBrief.length}',
      ];
      final modelThoughts = <String>[];
      final streamedMessageBuffers = <String, StringBuffer>{};
      final modifiedFiles = <String>[];
      var linesAdded = 0;
      var linesRemoved = 0;
      String completionMessage = '';
      String statusLine = 'Starting Copilot…';
      String liveContent = '';

      void emitProgress({
        String? status,
        String? streamedContent,
        bool isFinal = false,
      }) {
        if (status != null && status.trim().isNotEmpty) {
          statusLine = status.trim();
        }
        if (streamedContent != null) {
          liveContent = streamedContent;
        }

        onProgress?.call(
          AssistantExecutionUpdate(
            status: statusLine,
            thoughts: _tail(modelThoughts, 4),
            events: _tail(eventTimeline, 8),
            streamedContent: liveContent.isEmpty ? null : liveContent,
            isFinal: isFinal,
          ),
        );
      }

      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stdoutBuffer.writeln(line);
            final progressStatus = _captureJsonEvent(
              line: line,
              eventTimeline: eventTimeline,
              modelThoughts: modelThoughts,
              onCompletionDetected: (text) {
                if (text.trim().isNotEmpty) {
                  completionMessage = text.trim();
                }
              },
              onStreamingDeltaDetected: (messageId, deltaContent) {
                final buffer = streamedMessageBuffers.putIfAbsent(
                  messageId,
                  StringBuffer.new,
                );
                buffer.write(deltaContent);
                emitProgress(
                  status: 'Writing response…',
                  streamedContent: buffer.toString(),
                );
              },
              onStreamingMessageDetected: (messageId, content) {
                streamedMessageBuffers[messageId] = StringBuffer()
                  ..write(content);
                emitProgress(streamedContent: content);
              },
              onCodeChangesDetected: (files, added, removed) {
                modifiedFiles
                  ..clear()
                  ..addAll(files);
                linesAdded = added;
                linesRemoved = removed;
              },
            );
            emitProgress(status: progressStatus);
          })
          .asFuture<void>();

      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stderrBuffer.writeln(line);
            if (line.trim().isNotEmpty) {
              eventTimeline.add('stderr: ${line.trim()}');
            }
            emitProgress(status: 'Running Copilot…');
          })
          .asFuture<void>();

      emitProgress(status: 'Submitting prompt…');

      // Heartbeat: advance the status label every 6 s so the UI never looks
      // frozen if Copilot is quiet (e.g. during long planning or tool calls).
      var heartbeatTick = 0;
      final heartbeatLabels = [
        'Waiting for Copilot…',
        'Copilot is working…',
        'Still processing…',
        'Running tools…',
        'Almost there…',
      ];
      final heartbeat = Timer.periodic(const Duration(seconds: 6), (_) {
        heartbeatTick = (heartbeatTick + 1) % heartbeatLabels.length;
        emitProgress(status: heartbeatLabels[heartbeatTick]);
      });

      final exitCode = await process.exitCode;
      heartbeat.cancel();
      await Future.wait([stdoutDone, stderrDone]);

      if (completionMessage.isEmpty && modelThoughts.isNotEmpty) {
        completionMessage = modelThoughts.last;
      }

      emitProgress(status: 'Wrapping up…', isFinal: true);

      final resolvedStdout = completionMessage.isNotEmpty
          ? completionMessage
          : stdoutBuffer.toString();

      return CodexCliCommandResult(
        success: exitCode == 0,
        exitCode: exitCode,
        stdout: resolvedStdout,
        stderr: stderrBuffer.toString(),
        commandLine: commandLine,
        eventTimeline: eventTimeline,
        modelThoughts: modelThoughts,
        completionMessage: completionMessage.isEmpty ? null : completionMessage,
        modifiedFiles: modifiedFiles,
        linesAdded: linesAdded,
        linesRemoved: linesRemoved,
        executionStrategy: 'task-file',
        taskFilePath: taskFilePath,
        submittedPrimaryTask: submittedPrimaryTask,
      );
    } on ProcessException catch (error) {
      return CodexCliCommandResult(
        success: false,
        exitCode: null,
        stdout: '',
        stderr: error.message,
        executionStrategy: 'task-file',
      );
    } finally {
      if (tempDir != null && await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  static Future<CodexCliCommandResult> _run(
    String executable,
    List<String> arguments,
  ) async {
    try {
      final result = await Process.run(executable, arguments, runInShell: true);
      return CodexCliCommandResult(
        success: result.exitCode == 0,
        exitCode: result.exitCode,
        stdout: result.stdout?.toString() ?? '',
        stderr: result.stderr?.toString() ?? '',
      );
    } on ProcessException catch (error) {
      return CodexCliCommandResult(
        success: false,
        exitCode: null,
        stdout: '',
        stderr: error.message,
      );
    }
  }

  static String _combineProcessOutput(ProcessResult result) {
    final stdout = result.stdout?.toString() ?? '';
    final stderr = result.stderr?.toString() ?? '';
    return [
      if (stdout.trim().isNotEmpty) stdout.trim(),
      if (stderr.trim().isNotEmpty) stderr.trim(),
    ].join('\n\n');
  }

  static String _buildLoginProgress(List<String> lines, String? deviceCode) {
    final detailLines = <String>[
      'GitHub sign-in is running in your browser.',
      if (deviceCode != null)
        'One-time device code copied to clipboard: $deviceCode'
      else
        'If GitHub asks for a one-time code, it should already be in your clipboard.',
    ];

    final recentLines = _tail(lines, 6);
    if (recentLines.isNotEmpty) {
      detailLines
        ..add('')
        ..addAll(recentLines);
    }

    return detailLines.join('\n');
  }

  static String? _captureJsonEvent({
    required String line,
    required List<String> eventTimeline,
    required List<String> modelThoughts,
    required void Function(String text) onCompletionDetected,
    required void Function(String messageId, String deltaContent)
    onStreamingDeltaDetected,
    required void Function(String messageId, String content)
    onStreamingMessageDetected,
    required void Function(List<String> files, int added, int removed)
    onCodeChangesDetected,
  }) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      eventTimeline.add('stdout: ${_truncate(trimmed, 180)}');
      return null;
    }

    if (decoded is! Map) {
      eventTimeline.add('stdout: ${_truncate(trimmed, 180)}');
      return null;
    }

    final type = decoded['type']?.toString() ?? 'unknown';
    if (type == 'assistant.turn_start') {
      eventTimeline.add('assistant.turn_start');
      return 'Planning next steps…';
    }

    if (type == 'user.message') {
      final data = decoded['data'];
      if (data is Map) {
        final content = data['content']?.toString() ?? '';
        final primaryTask = _extractPrimaryTask(content);
        eventTimeline.add(
          primaryTask == null
              ? 'user.message chars=${content.length}'
              : 'user.message primary_task=${_truncate(primaryTask, 120)}',
        );
      } else {
        eventTimeline.add('user.message');
      }
      return 'Task submitted…';
    }

    if (type == 'assistant.message') {
      final data = decoded['data'];
      if (data is Map) {
        final messageId = data['messageId']?.toString() ?? '';
        final content = data['content']?.toString() ?? '';
        final phase = data['phase']?.toString() ?? 'unknown';
        final toolRequests = data['toolRequests'];
        final toolRequestCount = toolRequests is List ? toolRequests.length : 0;
        eventTimeline.add(
          'assistant.message phase=$phase chars=${content.length} tool_requests=$toolRequestCount',
        );
        if (content.trim().isNotEmpty) {
          modelThoughts.add(content.trim());
          if (messageId.isNotEmpty &&
              (phase == 'final_answer' ||
                  phase == 'complete' ||
                  phase == 'final' ||
                  phase == 'response')) {
            onStreamingMessageDetected(messageId, content);
          }
          if (phase == 'final_answer' ||
              phase == 'complete' ||
              phase == 'final' ||
              phase == 'response') {
            onCompletionDetected(content);
          }
        }
        if (toolRequestCount > 0) {
          return 'Preparing tool actions…';
        }
        return switch (phase) {
          'analysis' => 'Thinking…',
          'final_answer' ||
          'complete' ||
          'final' ||
          'response' => 'Writing final answer…',
          'tool_call' => 'Using a tool…',
          _ => 'Working…',
        };
      } else {
        // Some CLI versions put content at the top level (no 'data' wrapper).
        final topContent = decoded['content']?.toString() ?? '';
        if (topContent.trim().isNotEmpty) {
          modelThoughts.add(topContent.trim());
          eventTimeline.add(
            'assistant.message (top-level) chars=${topContent.length}',
          );
          onCompletionDetected(topContent);
        } else {
          eventTimeline.add('assistant.message');
        }
      }
      return 'Working…';
    }

    if (type == 'assistant.message_delta') {
      final data = decoded['data'];
      if (data is Map) {
        final messageId = data['messageId']?.toString() ?? '';
        final deltaContent = data['deltaContent']?.toString() ?? '';
        eventTimeline.add(
          'assistant.message_delta chars=${deltaContent.length}',
        );
        if (messageId.isNotEmpty && deltaContent.isNotEmpty) {
          onStreamingDeltaDetected(messageId, deltaContent);
          return 'Writing response…';
        }
      } else {
        eventTimeline.add('assistant.message_delta');
      }
      return 'Writing response…';
    }

    if (type == 'tool.execution_start') {
      final data = decoded['data'];
      if (data is Map) {
        final toolName = data['toolName']?.toString() ?? 'tool';
        eventTimeline.add('tool.execution_start $toolName');
        return _toolProgressLabel(toolName, starting: true);
      }
      eventTimeline.add('tool.execution_start');
      return 'Using a tool…';
    }

    if (type == 'tool.execution_complete') {
      final data = decoded['data'];
      if (data is Map) {
        final toolName = data['toolName']?.toString() ?? 'tool';
        final success = data['success'];
        final error = data['error'];
        if (error is Map) {
          final code = error['code']?.toString() ?? 'unknown';
          final message = error['message']?.toString() ?? '';
          eventTimeline.add(
            'tool.execution_complete $toolName success=$success error=$code ${_truncate(message, 120)}',
          );
          if (code == 'denied') {
            return 'Permission blocked $toolName…';
          }
        } else {
          eventTimeline.add(
            'tool.execution_complete $toolName success=$success',
          );
        }
        return _toolProgressLabel(toolName, starting: false);
      }
      eventTimeline.add('tool.execution_complete');
      return 'Processing tool results…';
    }

    if (type.startsWith('session.')) {
      eventTimeline.add(type);
      return switch (type) {
        'session.mcp_server_status_changed' => 'Connecting tools…',
        'session.mcp_servers_loaded' => 'Loading tools…',
        'session.skills_loaded' => 'Loading skills…',
        'session.tools_updated' => 'Preparing tool access…',
        _ => 'Starting Copilot…',
      };
    }

    if (type == 'result') {
      final resultExit = decoded['exitCode']?.toString() ?? '?';
      eventTimeline.add('result exit=$resultExit');

      // Extract the final response text that the Copilot agent places in the
      // result envelope (used when no assistant.message final-phase event was
      // emitted, e.g. with older or non-streaming CLI versions).
      final resultOutput =
          decoded['output']?.toString() ??
          decoded['message']?.toString() ??
          decoded['text']?.toString() ??
          '';
      if (resultOutput.trim().isNotEmpty) {
        onCompletionDetected(resultOutput.trim());
        eventTimeline.add('result.output chars=${resultOutput.trim().length}');
      }

      final usage = decoded['usage'];
      if (usage is Map) {
        final totalApiDuration = usage['totalApiDurationMs']?.toString() ?? '?';
        final sessionDuration = usage['sessionDurationMs']?.toString() ?? '?';
        eventTimeline.add(
          'usage total_api_ms=$totalApiDuration session_ms=$sessionDuration',
        );

        final codeChanges = usage['codeChanges'];
        if (codeChanges is Map) {
          final files = <String>[];
          final rawFiles = codeChanges['filesModified'];
          if (rawFiles is List) {
            for (final file in rawFiles) {
              final resolved = file?.toString().trim() ?? '';
              if (resolved.isNotEmpty) {
                files.add(resolved);
              }
            }
          }

          final added = _parseInt(codeChanges['linesAdded']);
          final removed = _parseInt(codeChanges['linesRemoved']);
          onCodeChangesDetected(files, added, removed);

          eventTimeline.add(
            'code_changes files=${files.length} lines_added=$added lines_removed=$removed',
          );
        }
      }
      return 'Finalizing…';
    }

    eventTimeline.add(type);
    return null;
  }

  static String _normalizeReasoningEffort(String input) {
    const allowed = {'low', 'medium', 'high', 'xhigh'};
    final effort = input.trim().toLowerCase();
    return allowed.contains(effort) ? effort : 'medium';
  }

  static int _parseInt(Object? value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _toolProgressLabel(String toolName, {required bool starting}) {
    final normalized = toolName.trim().toLowerCase();
    final action = switch (normalized) {
      'apply_patch' => starting ? 'Updating files…' : 'Files updated…',
      'powershell' => starting ? 'Running PowerShell…' : 'PowerShell finished…',
      'view' => starting ? 'Reading task brief…' : 'Task brief loaded…',
      'read_file' =>
        starting ? 'Reading project files…' : 'Project files loaded…',
      'search' =>
        starting ? 'Searching the codebase…' : 'Search results ready…',
      'report_intent' => starting ? 'Clarifying plan…' : 'Plan clarified…',
      _ => starting ? 'Using $toolName…' : 'Processed $toolName output…',
    };
    return action;
  }

  static String? _extractPrimaryTask(String prompt) {
    final match = RegExp(
      r'Primary task:\s*([\s\S]*?)(?:\n\n|\n[A-Z][^\n]*:|\n--- END USER MESSAGE ---|$)',
      caseSensitive: false,
    ).firstMatch(prompt);
    final raw = match?.group(1)?.trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _buildCompactTaskBrief(String prompt) {
    final systemSection = _extractPromptSection(prompt, 'SYSTEM INSTRUCTIONS');
    final userSection = _extractPromptSection(prompt, 'USER MESSAGE');
    final primaryTask =
        _extractPrimaryTask(prompt) ?? userSection.ifEmpty(prompt);
    final taskResolution = _extractNamedParagraph(
      userSection,
      'Task resolution:',
    );
    final activeFile = _extractSingleLineValue(userSection, 'Active file:');
    final inspectorMetadata = _extractBulletedBlock(
      userSection,
      'Active Flutter Inspector selection:',
    );
    final recentConversation = _extractRecentConversation(userSection);
    final hasInlineFileContents = userSection.contains('Open file contents:');
    final hasSourceExcerpt = userSection.contains(
      'Selected widget source excerpt:',
    );
    final needsInspectorResolution = systemSection.contains(
      'If the Primary task uses words like this, that, it, selected, or here',
    );

    final buffer = StringBuffer()
      ..writeln('Primary task:')
      ..writeln(primaryTask.trim());

    if (taskResolution != null ||
        (needsInspectorResolution && inspectorMetadata.isNotEmpty)) {
      buffer
        ..writeln()
        ..writeln('Task resolution:')
        ..writeln(
          taskResolution ??
              'Words like "this", "that", "it", "selected", or "here" refer to the Flutter Inspector metadata below.',
        );
    }

    if (activeFile != null) {
      buffer
        ..writeln()
        ..writeln('Active file: $activeFile');
    }

    if (inspectorMetadata.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Active Flutter Inspector selection:');
      for (final line in inspectorMetadata) {
        buffer.writeln('- ${_truncate(line, 220)}');
      }
    }

    if (recentConversation.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Recent conversation summary:');
      for (final entry in recentConversation) {
        buffer.writeln('- $entry');
      }
    }

    if (hasInlineFileContents || hasSourceExcerpt) {
      buffer
        ..writeln()
        ..writeln('Token-saving note:')
        ..writeln(
          'Inline file contents and source excerpts were omitted intentionally. Inspect local files only when needed.',
        );
    }

    return buffer.toString().trimRight();
  }

  static String _extractPromptSection(String prompt, String sectionName) {
    final escaped = RegExp.escape(sectionName);
    final match = RegExp(
      '--- $escaped ---\\s*([\\s\\S]*?)\\s*--- END $escaped ---',
      caseSensitive: false,
    ).firstMatch(prompt);
    return match?.group(1)?.trim() ?? '';
  }

  static String? _extractSingleLineValue(String text, String prefix) {
    for (final line in LineSplitter.split(text)) {
      if (line.startsWith(prefix)) {
        final value = line.substring(prefix.length).trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  static String? _extractNamedParagraph(String text, String heading) {
    final lines = LineSplitter.split(text).toList(growable: false);
    final startIndex = lines.indexWhere((line) => line.trim() == heading);
    if (startIndex == -1) {
      return null;
    }

    final collected = <String>[];
    for (var index = startIndex + 1; index < lines.length; index++) {
      final trimmed = lines[index].trim();
      if (trimmed.isEmpty || trimmed.startsWith('```')) {
        break;
      }
      collected.add(trimmed);
    }

    if (collected.isEmpty) {
      return null;
    }

    return collected.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static List<String> _extractBulletedBlock(String text, String heading) {
    final lines = LineSplitter.split(text).toList(growable: false);
    final startIndex = lines.indexWhere((line) => line.trim() == heading);
    if (startIndex == -1) {
      return const [];
    }

    final collected = <String>[];
    for (var index = startIndex + 1; index < lines.length; index++) {
      final trimmed = lines[index].trim();
      if (trimmed.isEmpty) {
        break;
      }
      if (!trimmed.startsWith('- ')) {
        break;
      }
      collected.add(trimmed.substring(2).trim());
    }

    return List<String>.unmodifiable(collected);
  }

  static List<String> _extractRecentConversation(String text) {
    final lines = LineSplitter.split(text).toList(growable: false);
    final startIndex = lines.indexWhere(
      (line) => line.trim() == 'Recent conversation (most recent last):',
    );
    if (startIndex == -1) {
      return const [];
    }

    final entries = <String>[];
    String? currentRole;
    var currentContent = <String>[];

    void flush() {
      if (currentRole == null || currentContent.isEmpty) {
        currentRole = null;
        currentContent = <String>[];
        return;
      }

      final content = currentContent
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (content.isNotEmpty) {
        entries.add('$currentRole: ${_truncate(content, 180)}');
      }
      currentRole = null;
      currentContent = <String>[];
    }

    for (var index = startIndex + 1; index < lines.length; index++) {
      final trimmed = lines[index].trim();
      if (trimmed.isEmpty) {
        flush();
        continue;
      }

      if (trimmed == 'User:' ||
          trimmed == 'Assistant:' ||
          trimmed == 'System:') {
        flush();
        currentRole = trimmed.substring(0, trimmed.length - 1);
        continue;
      }

      if (currentRole != null) {
        currentContent.add(trimmed);
      }
    }

    flush();
    return _tail(entries, 2);
  }

  static List<String> _permissionArguments(CopilotPermissionMode mode) {
    final arguments = <String>[];

    switch (mode) {
      case CopilotPermissionMode.readOnly:
        break;
      case CopilotPermissionMode.workspaceWrite:
        // GitHub's CLI requires auto-approval in prompt mode.
        arguments.add('--allow-all-tools');
        if (Platform.isWindows) {
          // On Windows, Copilot may choose shell tools that depend on pwsh.
          // Deny shell in workspace mode so file edits use native file tools.
          arguments.add('--deny-tool');
          arguments.add('shell');
        }
        break;
      case CopilotPermissionMode.fullAuto:
        arguments.add('--allow-all-tools');
        arguments.add('--allow-all-paths');
        break;
    }

    return arguments;
  }

  static String _formatCommandLine(List<String> arguments) {
    final escaped = arguments.map(_shellQuote).join(' ');
    return 'copilot $escaped';
  }

  static String? _extractDeviceCode(String value) {
    final match = RegExp(
      r'\b[A-Z0-9]{4}(?:-[A-Z0-9]{4})+\b',
    ).firstMatch(value.toUpperCase());
    return match?.group(0);
  }

  static String _stripAnsi(String value) {
    return value.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
  }

  static String _shellQuote(String value) {
    if (value.isEmpty) {
      return '""';
    }
    final needsQuote = value.contains(' ') || value.contains('"');
    if (!needsQuote) {
      return value;
    }
    return '"${value.replaceAll('"', r'\\"')}"';
  }

  static String _truncate(String value, int maxChars) {
    if (value.length <= maxChars) {
      return value;
    }
    return '${value.substring(0, maxChars)}...';
  }

  static List<String> _tail(List<String> items, int count) {
    if (items.length <= count) {
      return List<String>.unmodifiable(items);
    }
    return List<String>.unmodifiable(items.sublist(items.length - count));
  }
}

extension on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}
