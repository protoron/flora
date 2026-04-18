import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flora/core/models/flora_models.dart';
import 'package:flora/app/theme/flora_theme.dart';
import 'package:flora/core/state/flora_providers.dart';
import 'package:flora/features/chat/presentation/chat_workspace_pane.dart';
import 'package:flora/features/sidebar/presentation/project_sidebar_pane.dart';
import 'package:flora/features/shell/presentation/settings_overlay.dart';

// ─── Glass Window Wrapper ────────────────────────────────────────────────────

class GlassWindow extends StatelessWidget {
  const GlassWindow({required this.child, this.title, super.key});
  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: FloraPalette.glassPanel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FloraPalette.glassBorder, width: 0.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15), // match inner rounded border
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.white.withAlpha(150),
                  Colors.white.withAlpha(70),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: FloraPalette.border,
                          width: 0.5,
                        ),
                      ),
                      color: Colors.transparent, // Let the glass shine through
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          title!,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2, // More Apple-like typography
                            color: FloraPalette.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Top-level shell: title-bar + three resizable panes + status-bar.
class FloraShell extends ConsumerStatefulWidget {
  const FloraShell({super.key});

  @override
  ConsumerState<FloraShell> createState() => _FloraShellState();
}

class _FloraShellState extends ConsumerState<FloraShell> {
  static const double _splitterW = 12; // widened for gaps
  static const double _minPreviewW = 300;
  static const double _minChatW = 280;

  double _chatW = 340;
  bool _settingsOpen = false;

  void _resizeChat(double dx, double total) => setState(() {
    final max = total - _minPreviewW - _splitterW - 32; // -32 for padding
    // Going left (negative dx) means chat gets wider
    _chatW = (_chatW - dx).clamp(_minChatW, max);
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // Background Gradient Image Look
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFFE5E5EA), // Apple light gray
                  Color(0xFFF2F2F7), // Softer gray
                  Color(0xFFFFFFFF), // Pure white
                  Color(0xFFF9F9FB), // Very light gray-blue
                ],
                stops: [0.0, 0.4, 0.7, 1.0],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _TitleBar(
                  onSettings: () =>
                      setState(() => _settingsOpen = !_settingsOpen),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 8.0,
                    ),
                    child: LayoutBuilder(
                      builder: (ctx, cs) {
                        final total = cs.maxWidth;
                        return Row(
                          children: [
                            // Left: Live Preview (Takes most of the space)
                            Expanded(
                              child: const GlassWindow(
                                title: 'App Preview',
                                child: ProjectSidebarPane(),
                              ),
                            ),
                            _DragHandle(onDelta: (d) => _resizeChat(d, total)),
                            // Right: Chat
                            SizedBox(
                              width: _chatW,
                              child: const GlassWindow(
                                title: 'Chat Assistant',
                                child: ChatWorkspacePane(),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                const _StatusBar(),
              ],
            ),
          ),
          if (_settingsOpen)
            SettingsOverlay(
              onClose: () => setState(() => _settingsOpen = false),
            ),
        ],
      ),
    );
  }
}

// ─── Title Bar ───────────────────────────────────────────────────────────────

class _TitleBar extends ConsumerWidget {
  const _TitleBar({required this.onSettings});
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
        child: Container(
          height: 48, // slightly taller, roomier
          decoration: const BoxDecoration(
            color: FloraPalette.glassSidebar,
            border: Border(
              bottom: BorderSide(color: FloraPalette.border, width: 0.5),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Icon(
                Icons.local_florist,
                size: 16,
                color: FloraPalette.accent,
              ),
              const SizedBox(width: 8),
              const Text(
                'Flora',
                style: TextStyle(
                  color: FloraPalette.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                ),
              ),
              const Spacer(),
              _IconBtn(
                icon: Icons.more_horiz, // Apple-like minimal dots icon
                tooltip: 'Settings / AI Providers',
                onTap: onSettings,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Status Bar ──────────────────────────────────────────────────────────────

class _StatusBar extends ConsumerWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedAssistant = ref.watch(assistantProvider);
    final usingCodex = selectedAssistant == AssistantProviderType.codex;
    final providerInstalled = usingCodex
        ? ref.watch(codexInstalledProvider)
        : ref.watch(copilotInstalledProvider);
    final providerReady = usingCodex
        ? ref.watch(codexAuthenticatedProvider)
        : ref.watch(copilotAuthenticatedProvider);
    final providerLabel = usingCodex
        ? ref.watch(codexAuthLabelProvider)
        : ref.watch(copilotAuthLabelProvider);
    final root = ref.watch(projectRootProvider);
    final active = ref.watch(activeFilePathProvider);

    final projectName = root
        ?.split(RegExp(r'[/\\]'))
        .where((p) => p.isNotEmpty)
        .lastOrNull;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
        child: Container(
          height: 32, // cleaner
          decoration: const BoxDecoration(
            color: FloraPalette.glassSidebar,
            border: Border(
              top: BorderSide(color: FloraPalette.border, width: 0.5),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Icon(
                Icons.folder_shared_outlined,
                size: 13,
                color: FloraPalette.textSecondary,
              ),
              const SizedBox(width: 8),
              Text(
                projectName ?? 'No project',
                style: const TextStyle(
                  color: FloraPalette.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (active != null) ...[
                const _StatusDot(color: FloraPalette.textSecondary),
                Flexible(
                  fit: FlexFit.loose,
                  child: Tooltip(
                    message: active,
                    child: Text(
                      active,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: FloraPalette.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ],
              const Spacer(),
              _StatusIndicator(
                on: providerInstalled && providerReady,
                onLabel: '${selectedAssistant.label}: $providerLabel',
                offLabel: providerInstalled
                    ? '${selectedAssistant.label}: $providerLabel'
                    : (usingCodex
                          ? 'Install Codex CLI'
                          : 'Install GitHub Copilot CLI'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 5),
    child: Container(
      width: 3,
      height: 3,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    ),
  );
}

class _StatusIndicator extends StatelessWidget {
  const _StatusIndicator({
    required this.on,
    required this.onLabel,
    required this.offLabel,
  });
  final bool on;
  final String onLabel;
  final String offLabel;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: on ? FloraPalette.success : FloraPalette.error,
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 4),
      Text(
        on ? onLabel : offLabel,
        style: const TextStyle(color: FloraPalette.textPrimary, fontSize: 11),
      ),
    ],
  );
}

// ─── Drag Handle ─────────────────────────────────────────────────────────────

class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.onDelta});
  final void Function(double) onDelta;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      onHorizontalDragUpdate: (e) => onDelta(e.delta.dx),
      child: Container(
        width: _FloraShellState._splitterW,
        color: Colors.transparent, // Invisible gap between glassy windows
        child: Center(
          child: Container(
            width: 3,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
    ),
  );
}

// ─── Small icon button ────────────────────────────────────────────────────────

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.onTap, this.tooltip});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = InkWell(
      onTap: onTap,
      hoverColor: FloraPalette.hoveredBg,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 16, color: FloraPalette.textPrimary),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: btn) : btn;
  }
}
