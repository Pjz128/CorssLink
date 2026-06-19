import 'package:flutter/material.dart';
import '../models/protocol.dart';

/// Two-level picker: agent type (segmented) + model (dropdown).
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

    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final a in agents)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              final firstModel = a.models.isNotEmpty ? a.models.first.name : '';
              onChanged((a.type, firstModel));
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: a.type == selectedAgent ? cs.primary.withAlpha(30) : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: a.type == selectedAgent ? cs.primary.withAlpha(120) : cs.outlineVariant.withAlpha(60),
                  width: 0.5,
                ),
              ),
              child: Text(
                a.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: a.type == selectedAgent ? FontWeight.w600 : FontWeight.normal,
                  color: a.type == selectedAgent ? cs.primary : cs.onSurface.withAlpha(140),
                ),
              ),
            ),
          ),
        ),
      const SizedBox(width: 4),
      if (models.isNotEmpty)
        PopupMenuButton<String>(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(selectedModel.isNotEmpty ? selectedModel : models.first.name,
                style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(180))),
            Icon(Icons.arrow_drop_down, size: 16, color: cs.onSurface.withAlpha(120)),
          ]),
          onSelected: (m) => onChanged((selectedAgent ?? agents.first.type, m)),
          itemBuilder: (_) => models
              .map((m) => PopupMenuItem(
                    value: m.name,
                    child: Row(children: [
                      if (m.name == selectedModel) const Icon(Icons.check, size: 16) else const SizedBox(width: 16),
                      const SizedBox(width: 8), Text(m.name, style: const TextStyle(fontSize: 12)),
                    ]),
                  ))
              .toList(),
        ),
    ]);
  }
}
