import 'package:flutter/material.dart';

import '../models/protocol.dart';
import '../theme/crosslink_theme.dart';

/// 两级选择器：Agent 类型（胶囊） + 模型（下拉）。
/// Calls [onChanged] with the selected (agentType, modelName).
class AgentPicker extends StatelessWidget {
  final List<AgentInfo> agents;
  final String? selectedAgent;
  final String selectedModel;
  final void Function((String, String) sel) onChanged;

  const AgentPicker({
    super.key,
    required this.agents,
    required this.selectedAgent,
    required this.selectedModel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final models = agents
        .firstWhere((a) => a.type == selectedAgent, orElse: () => agents.first)
        .models;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final a in agents)
          Padding(
            padding: const EdgeInsets.only(right: CrossLinkTheme.sXs),
            child: InkWell(
              borderRadius: BorderRadius.circular(CrossLinkTheme.rXl),
              onTap: () {
                final firstModel = a.models.isNotEmpty ? a.models.first.name : '';
                onChanged((a.type, firstModel));
              },
              child: AnimatedContainer(
                duration: CrossLinkTheme.fast,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: a.type == selectedAgent
                      ? CrossLinkTheme.accent.withAlpha(40)
                      : CrossLinkTheme.surface.withAlpha(120),
                  borderRadius: BorderRadius.circular(CrossLinkTheme.rXl),
                  border: Border.all(
                    color: a.type == selectedAgent
                        ? CrossLinkTheme.accent.withAlpha(120)
                        : cs.outlineVariant.withAlpha(60),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  a.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: a.type == selectedAgent ? FontWeight.w600 : FontWeight.normal,
                    color: a.type == selectedAgent
                        ? CrossLinkTheme.accent
                        : cs.onSurface.withAlpha(180),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(width: CrossLinkTheme.sXs),
        if (models.isNotEmpty)
          PopupMenuButton<String>(
            constraints: const BoxConstraints(maxWidth: 240),
            color: CrossLinkTheme.surface,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  selectedModel.isNotEmpty ? selectedModel : models.first.name,
                  style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(200)),
                ),
                Icon(Icons.arrow_drop_down, size: 16, color: cs.onSurface.withAlpha(140)),
              ],
            ),
            onSelected: (m) => onChanged((selectedAgent ?? agents.first.type, m)),
            itemBuilder: (_) => models
                .map((m) => PopupMenuItem(
                      value: m.name,
                      child: Row(children: [
                        if (m.name == selectedModel)
                          const Icon(Icons.check, size: 16, color: CrossLinkTheme.accent)
                        else
                          const SizedBox(width: 16),
                        const SizedBox(width: 8),
                        Text(m.name, style: const TextStyle(fontSize: 12)),
                      ]),
                    ))
                .toList(),
          ),
      ],
    );
  }
}
