/// 发现页数据模型：在线 Agent 和建联申请。

class AgentMeta {
  final String type;
  final String label;
  final List<String> capabilities;

  AgentMeta({
    required this.type,
    required this.label,
    required this.capabilities,
  });

  factory AgentMeta.fromJson(Map<String, dynamic> json) {
    return AgentMeta(
      type: json['type'] as String? ?? '',
      label: json['label'] as String? ?? '',
      capabilities:
          (json['capabilities'] as List?)?.cast<String>() ?? [],
    );
  }
}

class DiscoveredAgent {
  final String peerID;
  final String connectedAt;
  final bool online;
  final String owner;
  final bool claimed;
  final String visibility;
  final bool isOwn;
  final bool canRequest;
  final AgentMeta? metadata;

  DiscoveredAgent({
    required this.peerID,
    required this.connectedAt,
    required this.online,
    required this.owner,
    required this.claimed,
    required this.visibility,
    required this.isOwn,
    required this.canRequest,
    this.metadata,
  });

  factory DiscoveredAgent.fromJson(Map<String, dynamic> json) {
    return DiscoveredAgent(
      peerID: json['peerID'] as String? ?? '',
      connectedAt: json['connectedAt'] as String? ?? '',
      online: json['online'] as bool? ?? false,
      owner: json['owner'] as String? ?? '',
      claimed: json['claimed'] as bool? ?? false,
      visibility: json['visibility'] as String? ?? 'private',
      isOwn: json['isOwn'] as bool? ?? false,
      canRequest: json['canRequest'] as bool? ?? false,
      metadata: json['metadata'] != null
          ? AgentMeta.fromJson(json['metadata'] as Map<String, dynamic>)
          : null,
    );
  }

  /// 在线时长（相对时间文本）
  String get onlineDuration {
    if (connectedAt.isEmpty) return '';
    try {
      final t = DateTime.parse(connectedAt);
      final d = DateTime.now().toUtc().difference(t);
      if (d.inDays > 0) return '已在线 ${d.inDays} 天';
      if (d.inHours > 0) return '已在线 ${d.inHours} 小时';
      if (d.inMinutes > 0) return '已在线 ${d.inMinutes} 分钟';
      return '刚刚上线';
    } catch (_) {
      return '';
    }
  }

  /// 归属状态文本
  String get ownerLabel {
    if (!claimed) return '未认领';
    if (isOwn) return '我的设备';
    return '持有者: $owner';
  }
}

class ConnectionRequest {
  final String requestId;
  final String peerID;
  final String toOwner;
  final String status;
  final String createdAt;
  final String? pairToken;

  ConnectionRequest({
    required this.requestId,
    required this.peerID,
    required this.toOwner,
    required this.status,
    required this.createdAt,
    this.pairToken,
  });

  factory ConnectionRequest.fromJson(Map<String, dynamic> json) {
    return ConnectionRequest(
      requestId: json['requestId'] as String? ?? '',
      peerID: json['peerID'] as String? ?? '',
      toOwner: json['toOwner'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      createdAt: json['createdAt'] as String? ?? '',
      pairToken: json['pairToken'] as String?,
    );
  }

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';
}
