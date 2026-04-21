import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/flora_models.dart';

enum CodexAuthMode { missing, loggedOut, chatgpt, apiKey, unknown }

class CodexCliStatus {
  const CodexCliStatus({
    required this.installed,
    required this.mode,
    required this.message,
  });

  final bool installed;
  final CodexAuthMode mode;
  final String message;

  bool get authenticated =>
      mode == CodexAuthMode.chatgpt || mode == CodexAuthMode.apiKey;

  String get badgeLabel {
    switch (mode) {
      case CodexAuthMode.chatgpt:
        return 'Codex ChatGPT';
      case CodexAuthMode.apiKey:
        return 'Codex API';
      case CodexAuthMode.loggedOut:
        return 'Codex signed out';
      case CodexAuthMode.unknown:
        return 'Codex unknown';
      case CodexAuthMode.missing:
        return 'Codex missing';
    }
  }
}

class CodexCliCommandResult {
  const CodexCliCommandResult({
    required this.success,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.commandLine = '',
    this.eventTimeline = const [],
    this.modelThoughts = const [],
    this.completionMessage,
    this.modifiedFiles = const [],
    this.linesAdded = 0,
    this.linesRemoved = 0,
    this.executionStrategy = 'direct-prompt',
    this.taskFilePath,
    this.submittedPrimaryTask,
  });

  final bool success;
  final int? exitCode;
  final String stdout;
  final String stderr;
  final String commandLine;
  final List<String> eventTimeline;
  final List<String> modelThoughts;
  final String? completionMessage;
  final List<String> modifiedFiles;
  final int linesAdded;
  final int linesRemoved;
  final String executionStrategy;
  final String? taskFilePath;
  final String? submittedPrimaryTask;

  String get combinedOutput {
    final parts = <String>[
      if (stdout.trim().isNotEmpty) stdout.trim(),
      if (stderr.trim().isNotEmpty) stderr.trim(),
    ];
    return parts.join('\n\n');
  }
}

class CodexCliService {
  const CodexCliService._();

  static const Duration _statusCacheTtl = Duration(seconds: 8);
  static CodexCliStatus? _cachedStatus;
  static DateTime? _cachedStatusAt;
  static Future<CodexCliStatus>? _statusProbe;

  static Future<CodexCliStatus> inspectStatus({bool forceRefresh = false}) {
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

  static Future<CodexCliStatus> _inspectStatusUncached() async {
    try {
      final version = await Process.run('codex', const [
        '--version',
      ], runInShell: true);

      if (version.exitCode != 0) {
        return CodexCliStatus(
          installed: false,
          mode: CodexAuthMode.missing,
          message: _combineProcessOutput(
            version,
          ).ifEmpty('Codex CLI is not installed.'),
        );
      }

      final status = await Process.run('codex', const [
        'login',
        'status',
      ], runInShell: true);
      final text = _combineProcessOutput(status).trim();
      final lower = text.toLowerCase();

      if (lower.contains('logged in using chatgpt')) {
        return CodexCliStatus(
          installed: true,
          mode: CodexAuthMode.chatgpt,
          message: text,
        );
      }

      if (lower.contains('logged in using an api key')) {
        return CodexCliStatus(
          installed: true,
          mode: CodexAuthMode.apiKey,
          message: text,
        );
      }

      if (lower.contains('not logged in')) {
        return CodexCliStatus(
          installed: true,
          mode: CodexAuthMode.loggedOut,
          message: text,
        );
      }

      return CodexCliStatus(
        installed: true,
        mode: CodexAuthMode.unknown,
        message: text.ifEmpty('Codex CLI is installed.'),
      );
    } on ProcessException catch (error) {
      return CodexCliStatus(
        installed: false,
        mode: CodexAuthMode.missing,
        message: error.message,
      );
    }
  }

  static Future<CodexCliCommandResult> install() async {
    final result = await _run('npm', const ['install', '-g', '@openai/codex']);
    if (result.success) {
      invalidateStatusCache();
    }
    return result;
  }

  static Future<CodexCliCommandResult> loginWithChatgpt() async {
    final result = await _run('codex', const ['login']);
    invalidateStatusCache();
    return result;
  }

  static Future<CodexCliCommandResult> loginWithDeviceCode() async {
    final result = await _run('codex', const ['login', '--device-auth']);
    invalidateStatusCache();
    return result;
  }

  static Future<CodexCliCommandResult> logout() async {
    final result = await _run('codex', const ['logout']);
    invalidateStatusCache();
    return result;
  }

  static Future<CodexCliCommandResult> execPrompt({
    required String prompt,
    required String workingDirectory,
    String model = 'gpt-5.4-mini',
    String reasoningEffort = 'medium',
    void Function(AssistantExecutionUpdate update)? onProgress,
  }) async {
    Directory? tempDir;
    final normalizedModel = model.trim().isEmpty
        ? 'gpt-5.4-mini'
        : model.trim();
    final normalizedReasoningEffort = _normalizeReasoningEffort(
      reasoningEffort,
    );

    try {
      tempDir = await Directory.systemTemp.createTemp('flora_codex_');
      final outputPath = p.join(tempDir.path, 'last_message.txt');
      final arguments = [
        'exec',
        '-',
        '-m',
        normalizedModel,
        '--config',
        'model_reasoning_effort="$normalizedReasoningEffort"',
        '--json',
        '--ephemeral',
        '--full-auto',
        '--sandbox',
        'workspace-write',
        '--skip-git-repo-check',
        '--cd',
        workingDirectory,
        '--output-last-message',
        outputPath,
      ];
      final commandLine = _formatCommandLine(arguments);

      final process = await Process.start(
        'codex',
        arguments,
        workingDirectory: workingDirectory,
        runInShell: true,
      );

      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final eventTimeline = <String>[];
      final modelThoughts = <String>[];
      String completionMessage = '';
      String statusLine = 'Starting Codex…';

      void emitProgress({String? status, bool isFinal = false}) {
        if (status != null && status.trim().isNotEmpty) {
          statusLine = status.trim();
        }

        onProgress?.call(
          AssistantExecutionUpdate(
            status: statusLine,
            thoughts: _tail(modelThoughts, 4),
            events: _tail(eventTimeline, 8),
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
            emitProgress(status: 'Running Codex…');
          })
          .asFuture<void>();

      emitProgress(status: 'Submitting prompt…');
      process.stdin.write(prompt);
      await process.stdin.close();

      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);

      String finalMessage = '';
      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        finalMessage = await outputFile.readAsString();
      }

      final trimmedFinal = finalMessage.trim();
      if (trimmedFinal.isNotEmpty) {
        completionMessage = trimmedFinal;
      }

      emitProgress(status: 'Wrapping up…', isFinal: true);

      final resolvedStdout = trimmedFinal.isNotEmpty
          ? finalMessage
          : (completionMessage.isNotEmpty
                ? completionMessage
                : stdoutBuffer.toString());

      return CodexCliCommandResult(
        success: exitCode == 0,
        exitCode: exitCode,
        stdout: resolvedStdout,
        stderr: stderrBuffer.toString(),
        commandLine: commandLine,
        eventTimeline: eventTimeline,
        modelThoughts: modelThoughts,
        completionMessage: completionMessage.isEmpty ? null : completionMessage,
      );
    } on ProcessException catch (error) {
      return CodexCliCommandResult(
        success: false,
        exitCode: null,
        stdout: '',
        stderr: error.message,
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

  static String _normalizeReasoningEffort(String input) {
    const allowed = {'none', 'minimal', 'low', 'medium', 'high', 'xhigh'};
    final effort = input.trim().toLowerCase();
    return allowed.contains(effort) ? effort : 'medium';
  }

  static String? _captureJsonEvent({
    required String line,
    required List<String> eventTimeline,
    required List<String> modelThoughts,
    required void Function(String text) onCompletionDetected,
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
    switch (type) {
      case 'thread.started':
        final threadId = decoded['thread_id']?.toString() ?? 'unknown';
        eventTimeline.add('thread.started id=$threadId');
        return 'Starting Codex thread…';
      case 'turn.started':
        eventTimeline.add('turn.started');
        return 'Thinking…';
      case 'turn.completed':
        final usage = decoded['usage'];
        if (usage is Map) {
          eventTimeline.add('turn.completed ${_formatUsage(usage)}');
        } else {
          eventTimeline.add('turn.completed');
        }
        return 'Reviewing results…';
      case 'item.started':
      case 'item.completed':
        final item = decoded['item'];
        if (item is! Map) {
          eventTimeline.add(type);
          return null;
        }

        final itemType = item['type']?.toString() ?? 'unknown';
        if (itemType == 'agent_message') {
          final text = item['text']?.toString() ?? '';
          if (text.trim().isNotEmpty) {
            modelThoughts.add(text.trim());
            onCompletionDetected(text);
          }
          eventTimeline.add('$type agent_message chars=${text.length}');
          return 'Drafting response…';
        }

        if (itemType == 'command_execution') {
          final status = item['status']?.toString() ?? 'unknown';
          final exitCode = item['exit_code']?.toString() ?? '-';
          eventTimeline.add(
            '$type command_execution status=$status exit=$exitCode',
          );

          final output = item['aggregated_output']?.toString() ?? '';
          if (type == 'item.completed' && output.trim().isNotEmpty) {
            final singleLine = output
                .replaceAll('\r\n', '\n')
                .replaceAll('\r', '\n')
                .replaceAll('\n', ' | ')
                .trim();
            eventTimeline.add('command.output: ${_truncate(singleLine, 180)}');
          }
          return 'Running tool execution…';
        }

        eventTimeline.add('$type $itemType');
        return null;
      default:
        eventTimeline.add(type);
        return null;
    }
  }

  static List<String> _tail(List<String> items, int count) {
    if (items.length <= count) {
      return List<String>.unmodifiable(items);
    }
    return List<String>.unmodifiable(items.sublist(items.length - count));
  }

  static String _formatUsage(Map usage) {
    final inputTokens = usage['input_tokens']?.toString() ?? '?';
    final outputTokens = usage['output_tokens']?.toString() ?? '?';
    final cachedInputTokens = usage['cached_input_tokens']?.toString() ?? '?';
    return 'input=$inputTokens output=$outputTokens cached_input=$cachedInputTokens';
  }

  static String _formatCommandLine(List<String> arguments) {
    final escaped = arguments.map(_shellQuote).join(' ');
    return 'codex $escaped';
  }

  static String _shellQuote(String value) {
    if (value.isEmpty) {
      return '""';
    }
    final needsQuote = value.contains(' ') || value.contains('"');
    if (!needsQuote) {
      return value;
    }
    return '"${value.replaceAll('"', r'\"')}"';
  }

  static String _truncate(String value, int maxChars) {
    if (value.length <= maxChars) {
      return value;
    }
    return '${value.substring(0, maxChars)}...';
  }
}

extension on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}
