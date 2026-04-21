import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../models/flora_models.dart';

// ─── Auth ────────────────────────────────────────────────────────────────────

/// Injected at startup from SharedPreferences (see main.dart).
final openAIKeyInitialProvider = Provider<String?>((ref) => null);

/// Injected at startup from SharedPreferences (see main.dart).
final projectRootInitialProvider = Provider<String?>((ref) => null);

/// Injected at startup from SharedPreferences (see main.dart).
final assistantProviderInitialProvider = Provider<AssistantProviderType>(
  (ref) => normalizeAssistantProvider(AssistantProviderType.codex),
);

/// Injected at startup by probing the local Codex CLI installation.
final codexInstalledInitialProvider = Provider<bool>((ref) => false);

/// Injected at startup by probing `codex login status`.
final codexAuthenticatedInitialProvider = Provider<bool>((ref) => false);

/// Injected at startup by probing `codex login status`.
final codexAuthLabelInitialProvider = Provider<String>(
  (ref) => 'Codex not configured',
);

/// Injected at startup by probing the local Copilot CLI installation.
final copilotInstalledInitialProvider = Provider<bool>((ref) => false);

/// Injected at startup by probing Copilot authentication state.
final copilotAuthenticatedInitialProvider = Provider<bool>((ref) => false);

/// Injected at startup by probing Copilot authentication state.
final copilotAuthLabelInitialProvider = Provider<String>(
  (ref) => 'GitHub Copilot not configured',
);

/// Injected at startup from SharedPreferences (see main.dart).
final codexModelInitialProvider = Provider<String>((ref) => 'gpt-5.4-mini');

/// Injected at startup from SharedPreferences (see main.dart).
final codexReasoningEffortInitialProvider = Provider<String>((ref) => 'medium');

/// Injected at startup from SharedPreferences (see main.dart).
final copilotModelInitialProvider = Provider<String>((ref) => 'gpt-5.2');

/// Injected at startup from SharedPreferences (see main.dart).
final copilotReasoningEffortInitialProvider = Provider<String>(
  (ref) => 'medium',
);

/// Injected at startup from SharedPreferences (see main.dart).
final copilotPermissionModeInitialProvider = Provider<CopilotPermissionMode>(
  (ref) => CopilotPermissionMode.workspaceWrite,
);

/// Live-writable copy. Write here to update the key at runtime.
final openAIKeyProvider = StateProvider<String?>((ref) {
  return ref.watch(openAIKeyInitialProvider);
});

final assistantProvider = StateProvider<AssistantProviderType>((ref) {
  return normalizeAssistantProvider(
    ref.watch(assistantProviderInitialProvider),
  );
});

final codexInstalledProvider = StateProvider<bool>((ref) {
  return ref.watch(codexInstalledInitialProvider);
});

final codexAuthenticatedProvider = StateProvider<bool>((ref) {
  return ref.watch(codexAuthenticatedInitialProvider);
});

final codexAuthLabelProvider = StateProvider<String>((ref) {
  return ref.watch(codexAuthLabelInitialProvider);
});

final copilotInstalledProvider = StateProvider<bool>((ref) {
  return ref.watch(copilotInstalledInitialProvider);
});

final copilotAuthenticatedProvider = StateProvider<bool>((ref) {
  return ref.watch(copilotAuthenticatedInitialProvider);
});

final copilotAuthLabelProvider = StateProvider<String>((ref) {
  return ref.watch(copilotAuthLabelInitialProvider);
});

final codexModelProvider = StateProvider<String>((ref) {
  return ref.watch(codexModelInitialProvider);
});

final codexReasoningEffortProvider = StateProvider<String>((ref) {
  return ref.watch(codexReasoningEffortInitialProvider);
});

final copilotModelProvider = StateProvider<String>((ref) {
  return ref.watch(copilotModelInitialProvider);
});

final copilotReasoningEffortProvider = StateProvider<String>((ref) {
  return ref.watch(copilotReasoningEffortInitialProvider);
});

final copilotPermissionModeProvider = StateProvider<CopilotPermissionMode>((
  ref,
) {
  return ref.watch(copilotPermissionModeInitialProvider);
});

// Trigger integer to prompt a hot reload from anywhere
final hotReloadTriggerProvider = StateProvider<int>((ref) => 0);

// ─── Preview ─────────────────────────────────────────────────────────────────

/// DevTools URL to load in the embedded webview (e.g. http://127.0.0.1:9100).
final devToolsUrlProvider = StateProvider<String?>((ref) => null);

/// Latest widget selected in Flutter Inspector / DevTools.
final inspectorSelectionProvider = StateProvider<InspectorSelectionContext?>(
  (ref) => null,
);

/// Recently targeted widgets kept for quick annotation follow-ups.
final inspectorSelectionHistoryProvider =
    StateProvider<List<InspectorSelectionContext>>((ref) => const []);

/// Whether the preview is in normal interaction mode or UI targeting mode.
final previewInteractionModeProvider = StateProvider<PreviewInteractionMode>((
  ref,
) {
  return PreviewInteractionMode.use;
});

// ─── Chat ─────────────────────────────────────────────────────────────────────

final chatHistoryProvider = StateProvider<List<ChatMessage>>((ref) => const []);
final chatActiveRequestCountProvider = StateProvider<int>((ref) => 0);
final chatLoadingProvider = Provider<bool>((ref) {
  return ref.watch(chatActiveRequestCountProvider) > 0;
});
final chatComposerTextProvider = StateProvider<String>((ref) => '');

// ─── File Explorer ────────────────────────────────────────────────────────────

/// Absolute path of the root project folder being explored.
final projectRootProvider = StateProvider<String?>((ref) {
  return ref.watch(projectRootInitialProvider);
});

/// Absolute paths of expanded folders in the tree.
final expandedFoldersProvider = StateProvider<Set<String>>((ref) => const {});

/// Absolute path of the currently selected / active file.
final activeFilePathProvider = StateProvider<String?>((ref) => null);
