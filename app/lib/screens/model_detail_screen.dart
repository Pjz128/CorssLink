import 'package:flutter/material.dart';
import '../models/protocol.dart';
import '../services/settings_service.dart';
import '../theme/crosslink_theme.dart';

class ModelDetailScreen extends StatelessWidget {
  final AgentInfo agentInfo;
  final ModelInfo model;

  const ModelDetailScreen({super.key, required this.agentInfo, required this.model});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(model.name),
        backgroundColor: CrossLinkTheme.surface,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Model icon
          Center(
            child: Icon(Icons.memory, size: 72, color: CrossLinkTheme.accent),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(model.name,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text('由 ${agentInfo.label} 提供',
                style: TextStyle(color: CrossLinkTheme.textMuted)),
          ),
          const SizedBox(height: 24),

          // Metadata card
          Card(
            color: CrossLinkTheme.deepSpaceCard,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('模型信息', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const Divider(),
                  _InfoRow(label: '参数规模', value: model.paramSize),
                  _InfoRow(label: '量化方式', value: model.quant),
                  _InfoRow(label: 'Agent 类型', value: agentInfo.type),
                  _InfoRow(label: 'Agent 名称', value: agentInfo.label),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Set as default button
          FilledButton.icon(
            onPressed: () {
              final settings = SettingsService.open();
              settings.model = model.name;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已将 ${model.name} 设为默认模型')),
              );
            },
            icon: const Icon(Icons.star),
            label: const Text('设为默认模型'),
          ),
          const SizedBox(height: 8),

          // Test chat button
          OutlinedButton.icon(
            onPressed: () {
              // TODO: navigate to chat with this model pre-selected
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请在会话页面新建对话时选择此模型')),
              );
            },
            icon: const Icon(Icons.chat),
            label: const Text('新建对话'),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: CrossLinkTheme.textMuted)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
