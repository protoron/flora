import 'package:flutter/material.dart';

enum MessageRole { user, assistant, system }

enum LogLevel { info, warning, error }

enum AssistantProviderType { codex, copilot }

enum CopilotPermissionMode { readOnly, workspaceWrite, fullAuto }

enum PreviewInteractionMode { use, annotate }

/// Feature flag for enabling or disabling Codex integration in Flora.
const bool codexIntegrationEnabled = true;

List<AssistantProviderType> enabledAssistantProviders() {
  if (codexIntegrationEnabled) {
    return AssistantProviderType.values;
  }
  return const [AssistantProviderType.copilot];
}

AssistantProviderType normalizeAssistantProvider(
  AssistantProviderType provider,
) {
  if (!codexIntegrationEnabled && provider == AssistantProviderType.codex) {
    return AssistantProviderType.copilot;
  }
  return provider;
}

AssistantProviderType assistantProviderFromKey(String? value) {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'copilot':
      return AssistantProviderType.copilot;
    case 'codex':
      return normalizeAssistantProvider(AssistantProviderType.codex);
    default:
      return normalizeAssistantProvider(AssistantProviderType.codex);
  }
}

extension AssistantProviderTypeX on AssistantProviderType {
  String get key {
    switch (this) {
      case AssistantProviderType.codex:
        return 'codex';
      case AssistantProviderType.copilot:
        return 'copilot';
    }
  }

  String get label {
    switch (this) {
      case AssistantProviderType.codex:
        return 'Codex';
      case AssistantProviderType.copilot:
        return 'GitHub Copilot';
    }
  }
}

CopilotPermissionMode copilotPermissionModeFromKey(String? value) {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'read_only':
    case 'read-only':
    case 'readonly':
      return CopilotPermissionMode.readOnly;
    case 'full_auto':
    case 'full-auto':
    case 'fullauto':
      return CopilotPermissionMode.fullAuto;
    case 'workspace_write':
    case 'workspace-write':
    case 'workspacewrite':
    default:
      return CopilotPermissionMode.workspaceWrite;
  }
}

extension CopilotPermissionModeX on CopilotPermissionMode {
  String get key {
    switch (this) {
      case CopilotPermissionMode.readOnly:
        return 'read_only';
      case CopilotPermissionMode.workspaceWrite:
        return 'workspace_write';
      case CopilotPermissionMode.fullAuto:
        return 'full_auto';
    }
  }

  String get label {
    switch (this) {
      case CopilotPermissionMode.readOnly:
        return 'Read only';
      case CopilotPermissionMode.workspaceWrite:
        return 'Workspace edits';
      case CopilotPermissionMode.fullAuto:
        return 'Full auto';
    }
  }

  String get description {
    switch (this) {
      case CopilotPermissionMode.readOnly:
        return 'No write auto-approval. In Flora prompt mode, edit requests will be denied.';
      case CopilotPermissionMode.workspaceWrite:
        return 'Auto-approve tools for non-interactive runs while keeping file access limited to the project directory and explicitly allowed paths. On Windows, direct shell execution is denied in this mode so edits use native file tools.';
      case CopilotPermissionMode.fullAuto:
        return 'Auto-approve all tools and paths for the current session.';
    }
  }
}

extension PreviewInteractionModeX on PreviewInteractionMode {
  String get key {
    switch (this) {
      case PreviewInteractionMode.use:
        return 'use';
      case PreviewInteractionMode.annotate:
        return 'annotate';
    }
  }

  String get label {
    switch (this) {
      case PreviewInteractionMode.use:
        return 'Use App';
      case PreviewInteractionMode.annotate:
        return 'Annotate UI';
    }
  }

  String get helperText {
    switch (this) {
      case PreviewInteractionMode.use:
        return 'Interact with the running app normally. Your last UI target stays attached for chat until you clear it.';
      case PreviewInteractionMode.annotate:
        return 'Browse a Flora-owned screen map of the current widget tree, then target the right layout container without freezing the app preview.';
    }
  }
}

class FloraProject {
  const FloraProject({
    required this.name,
    required this.repoPath,
    required this.branch,
    required this.environment,
    required this.flutterVersion,
    required this.workspaceName,
    required this.runtimeStatus,
  });

  final String name;
  final String repoPath;
  final String branch;
  final String environment;
  final String flutterVersion;
  final String workspaceName;
  final String runtimeStatus;
}

class SidebarGroup {
  const SidebarGroup({required this.title, required this.items});

  final String title;
  final List<SidebarItem> items;
}

class SidebarItem {
  const SidebarItem({required this.label, required this.icon, this.badge});

  final String label;
  final IconData icon;
  final String? badge;
}

class ProjectFileEntry {
  const ProjectFileEntry({
    required this.label,
    required this.path,
    required this.depth,
    this.isFolder = false,
    this.isDirty = false,
    this.aiTouched = false,
  });

  final String label;
  final String path;
  final int depth;
  final bool isFolder;
  final bool isDirty;
  final bool aiTouched;
}

class PromptTemplate {
  const PromptTemplate({
    required this.title,
    required this.summary,
    required this.commandHint,
  });

  final String title;
  final String summary;
  final String commandHint;
}

class ChatContextChip {
  const ChatContextChip({required this.label, required this.tint});

  final String label;
  final Color tint;
}

class WidgetSelection {
  const WidgetSelection({
    required this.widgetId,
    required this.widgetName,
    required this.sourceFile,
    required this.line,
    required this.routeName,
    required this.ancestors,
    required this.stateBindings,
    required this.recentIssues,
    required this.constraints,
    required this.size,
    required this.semanticsLabel,
    required this.buildCount,
    required this.summary,
    required this.accentColor,
  });

  final String widgetId;
  final String widgetName;
  final String sourceFile;
  final int line;
  final String routeName;
  final List<String> ancestors;
  final List<String> stateBindings;
  final List<String> recentIssues;
  final String constraints;
  final String size;
  final String semanticsLabel;
  final int buildCount;
  final String summary;
  final Color accentColor;
}

class InspectorSelectionContext {
  const InspectorSelectionContext({
    required this.valueId,
    required this.widgetName,
    required this.description,
    required this.sourceFile,
    required this.line,
    required this.endLine,
    required this.column,
    required this.ancestorPath,
    required this.capturedAt,
  });

  final String? valueId;
  final String widgetName;
  final String description;
  final String? sourceFile;
  final int? line;
  final int? endLine;
  final int? column;
  final List<String> ancestorPath;
  final DateTime capturedAt;
}

class InspectorTreeSnapshot {
  const InspectorTreeSnapshot({
    required this.groupName,
    required this.capturedAt,
    required this.rootNodes,
    required this.totalNodeCount,
    required this.layoutNodeCount,
    required this.controlNodeCount,
    required this.textNodeCount,
  });

  final String groupName;
  final DateTime capturedAt;
  final List<InspectorTreeNode> rootNodes;
  final int totalNodeCount;
  final int layoutNodeCount;
  final int controlNodeCount;
  final int textNodeCount;
}

class InspectorTreeNode {
  const InspectorTreeNode({
    required this.valueId,
    required this.stableKey,
    required this.widgetName,
    required this.description,
    required this.textPreview,
    required this.sourceFile,
    required this.line,
    required this.endLine,
    required this.column,
    required this.createdByLocalProject,
    required this.ancestorPath,
    required this.depth,
    required this.children,
  });

  final String? valueId;
  final String stableKey;
  final String widgetName;
  final String description;
  final String? textPreview;
  final String? sourceFile;
  final int? line;
  final int? endLine;
  final int? column;
  final bool createdByLocalProject;
  final List<String> ancestorPath;
  final int depth;
  final List<InspectorTreeNode> children;

  InspectorSelectionContext toSelectionContext() {
    return InspectorSelectionContext(
      valueId: valueId,
      widgetName: widgetName,
      description: description,
      sourceFile: sourceFile,
      line: line,
      endLine: endLine,
      column: column,
      ancestorPath: ancestorPath,
      capturedAt: DateTime.now(),
    );
  }
}

class InspectorNodeLayoutDetails {
  const InspectorNodeLayoutDetails({
    required this.constraintsDescription,
    required this.width,
    required this.height,
    required this.flexFactor,
    required this.flexFit,
    required this.offsetX,
    required this.offsetY,
    required this.textPreview,
    required this.renderObjectDescription,
    required this.parentRenderElementDescription,
  });

  final String? constraintsDescription;
  final double? width;
  final double? height;
  final int? flexFactor;
  final String? flexFit;
  final double? offsetX;
  final double? offsetY;
  final String? textPreview;
  final String? renderObjectDescription;
  final String? parentRenderElementDescription;
}

class AssistantExecutionUpdate {
  const AssistantExecutionUpdate({
    required this.status,
    this.thoughts = const [],
    this.events = const [],
    this.streamedContent,
    this.isFinal = false,
  });

  final String status;
  final List<String> thoughts;
  final List<String> events;
  final String? streamedContent;
  final bool isFinal;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.timestamp,
    this.inspectorAttachment,
    this.model,
    this.reasoningEffort,
    this.assistantProvider,
    this.thoughts = const [],
    this.completionSummary,
    this.debugLines = const [],
    this.isStreaming = false,
  });

  final String id;
  final MessageRole role;
  final String content;
  final DateTime? timestamp;
  final InspectorSelectionContext? inspectorAttachment;
  final String? model;
  final String? reasoningEffort;
  final AssistantProviderType? assistantProvider;
  final List<String> thoughts;
  final String? completionSummary;
  final List<String> debugLines;
  final bool isStreaming;

  ChatMessage copyWith({
    String? id,
    MessageRole? role,
    String? content,
    DateTime? timestamp,
    InspectorSelectionContext? inspectorAttachment,
    String? model,
    String? reasoningEffort,
    AssistantProviderType? assistantProvider,
    List<String>? thoughts,
    String? completionSummary,
    List<String>? debugLines,
    bool? isStreaming,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      inspectorAttachment: inspectorAttachment ?? this.inspectorAttachment,
      model: model ?? this.model,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      assistantProvider: assistantProvider ?? this.assistantProvider,
      thoughts: thoughts ?? this.thoughts,
      completionSummary: completionSummary ?? this.completionSummary,
      debugLines: debugLines ?? this.debugLines,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }
}

class RuntimeMetric {
  const RuntimeMetric({
    required this.label,
    required this.value,
    required this.context,
  });

  final String label;
  final String value;
  final String context;
}

class RuntimeLogEntry {
  const RuntimeLogEntry({
    required this.level,
    required this.timestamp,
    required this.message,
  });

  final LogLevel level;
  final String timestamp;
  final String message;
}

class DeploymentRun {
  const DeploymentRun({
    required this.target,
    required this.environment,
    required this.platform,
    required this.status,
    required this.initiator,
    required this.timestamp,
    required this.tint,
  });

  final String target;
  final String environment;
  final String platform;
  final String status;
  final String initiator;
  final String timestamp;
  final Color tint;
}

class PreflightCheck {
  const PreflightCheck({
    required this.label,
    required this.passed,
    required this.detail,
  });

  final String label;
  final bool passed;
  final String detail;
}
