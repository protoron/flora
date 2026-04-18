import 'dart:convert';
import 'dart:io';

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

  static Future<CopilotCliStatus> inspectStatus() async {
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
            'Run gh auth login and then copilot login.',
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

    return result;
  }

  static Future<CodexCliCommandResult> login() {
    return _run('copilot', const ['login']);
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

  static Future<CodexCliCommandResult> execPrompt({
    required String prompt,
    required String workingDirectory,
    String model = 'gpt-5.2',
    String reasoningEffort = 'medium',
    void Function(AssistantExecutionUpdate update)? onProgress,
  }) async {
    final normalizedModel = model.trim().isEmpty ? 'gpt-5.2' : model.trim();
    final normalizedReasoningEffort = _normalizeReasoningEffort(
      reasoningEffort,
    );

    try {
      final arguments = [
        '-p',
        prompt,
        '--allow-all-tools',
        '--stream',
        'off',
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

      final commandLine = 'copilot ${arguments.map(_shellQuote).join(' ')}';
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final eventTimeline = <String>[];
      final modelThoughts = <String>[];
      String completionMessage = '';
      String statusLine = 'Starting Copilot…';

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
            emitProgress(status: 'Running Copilot…');
          })
          .asFuture<void>();

      emitProgress(status: 'Submitting prompt…');
      final exitCode = await process.exitCode;
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
    if (type == 'assistant.message') {
      final data = decoded['data'];
      if (data is Map) {
        final content = data['content']?.toString() ?? '';
        final phase = data['phase']?.toString() ?? 'unknown';
        eventTimeline.add(
          'assistant.message phase=$phase chars=${content.length}',
        );
        if (content.trim().isNotEmpty) {
          modelThoughts.add(content.trim());
          if (phase == 'final_answer') {
            onCompletionDetected(content);
          }
        }
        return switch (phase) {
          'analysis' => 'Thinking…',
          'final_answer' => 'Writing final answer…',
          'tool_call' => 'Using a tool…',
          _ => 'Working…',
        };
      } else {
        eventTimeline.add('assistant.message');
      }
      return 'Working…';
    }

    if (type == 'result') {
      final resultExit = decoded['exitCode']?.toString() ?? '?';
      eventTimeline.add('result exit=$resultExit');
      final usage = decoded['usage'];
      if (usage is Map) {
        final totalApiDuration = usage['totalApiDurationMs']?.toString() ?? '?';
        final sessionDuration = usage['sessionDurationMs']?.toString() ?? '?';
        eventTimeline.add(
          'usage total_api_ms=$totalApiDuration session_ms=$sessionDuration',
        );
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
