import 'dart:convert';
import 'dart:typed_data';

class PairingQrPayload {
  final String baseUrl;
  final String token;
  final String machineId;
  final String machineName;
  final String cloudflareUrl;
  final String sessionId;
  final bool hasPairPath;

  const PairingQrPayload({
    required this.baseUrl,
    required this.token,
    required this.machineId,
    required this.machineName,
    required this.cloudflareUrl,
    required this.sessionId,
    this.hasPairPath = false,
  });

  bool get looksLikePairingCode =>
      hasPairPath || token.isNotEmpty || machineId.isNotEmpty || cloudflareUrl.isNotEmpty;

  static PairingQrPayload? tryParse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map) return null;
        final rawBase = (decoded['baseUrl'] ?? '').toString().trim();
        final baseUri = Uri.tryParse(rawBase);
        if (baseUri == null || !baseUri.hasScheme || baseUri.host.isEmpty) return null;
        if (baseUri.scheme != 'http' && baseUri.scheme != 'https') return null;
        final origin = '${baseUri.scheme}://${baseUri.authority}';
        final machId = (decoded['machineId'] ?? '').toString();
        return PairingQrPayload(
          baseUrl: origin,
          token: (decoded['token'] ?? '').toString(),
          machineId: machId,
          machineName: (decoded['machineName'] ?? baseUri.host).toString(),
          cloudflareUrl: (decoded['cloudflareUrl'] ?? '').toString().replaceAll(RegExp(r'/+$'), ''),
          sessionId: (decoded['sessionId'] ?? machId).toString(),
          hasPairPath: true,
        );
      } catch (_) {
        return null;
      }
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;

    final origin = '${uri.scheme}://${uri.authority}';
    return PairingQrPayload(
      baseUrl: origin,
      token: uri.queryParameters['t'] ?? '',
      machineId: uri.queryParameters['m'] ?? '',
      machineName: uri.queryParameters['n'] ?? uri.host,
      cloudflareUrl: (uri.queryParameters['cf'] ?? '').replaceAll(RegExp(r'/+$'), ''),
      sessionId: uri.queryParameters['s'] ?? uri.queryParameters['m'] ?? '',
      hasPairPath: uri.path.contains('/pair'),
    );
  }
}

class SavedMachine {
  final String machineId;
  final String machineName;
  final String lanUrl;
  final String cloudflareUrl;
  final String sessionId;
  final String deviceToken;
  final String edgeDeviceToken;
  final int lastConnectedAtMs;

  const SavedMachine({
    required this.machineId,
    required this.machineName,
    required this.lanUrl,
    required this.cloudflareUrl,
    required this.sessionId,
    required this.deviceToken,
    this.edgeDeviceToken = '',
    required this.lastConnectedAtMs,
  });

  SavedMachine copyWith({
    String? machineName,
    String? lanUrl,
    String? cloudflareUrl,
    String? sessionId,
    String? deviceToken,
    String? edgeDeviceToken,
    int? lastConnectedAtMs,
  }) {
    return SavedMachine(
      machineId: machineId,
      machineName: machineName ?? this.machineName,
      lanUrl: lanUrl ?? this.lanUrl,
      cloudflareUrl: cloudflareUrl ?? this.cloudflareUrl,
      sessionId: sessionId ?? this.sessionId,
      deviceToken: deviceToken ?? this.deviceToken,
      edgeDeviceToken: edgeDeviceToken ?? this.edgeDeviceToken,
      lastConnectedAtMs: lastConnectedAtMs ?? this.lastConnectedAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
    'machineId': machineId,
    'machineName': machineName,
    'lanUrl': lanUrl,
    'cloudflareUrl': cloudflareUrl,
    'sessionId': sessionId,
    'deviceToken': deviceToken,
    'edgeDeviceToken': edgeDeviceToken,
    'lastConnectedAtMs': lastConnectedAtMs,
  };

  factory SavedMachine.fromJson(Map<String, dynamic> json) => SavedMachine(
    machineId: (json['machineId'] ?? '').toString(),
    machineName: (json['machineName'] ?? 'Antigravity PC').toString(),
    lanUrl: (json['lanUrl'] ?? '').toString(),
    cloudflareUrl: (json['cloudflareUrl'] ?? '').toString(),
    sessionId: (json['sessionId'] ?? '').toString(),
    deviceToken: (json['deviceToken'] ?? '').toString(),
    edgeDeviceToken: (json['edgeDeviceToken'] ?? '').toString(),
    lastConnectedAtMs: (json['lastConnectedAtMs'] as num?)?.toInt() ?? 0,
  );
}

class PairedMobileDevice {
  final String id;
  final String name;
  final String platform;
  final int pairedAtMs;
  final int lastSeenAtMs;
  final bool online;
  final String transport;
  final String remoteAddress;

  const PairedMobileDevice({
    required this.id,
    required this.name,
    this.platform = 'mobile',
    this.pairedAtMs = 0,
    this.lastSeenAtMs = 0,
    this.online = false,
    this.transport = '',
    this.remoteAddress = '',
  });

  factory PairedMobileDevice.fromJson(Map<String, dynamic> json) => PairedMobileDevice(
    id: (json['id'] ?? '').toString(),
    name: (json['name'] ?? 'Mobile Device').toString(),
    platform: (json['platform'] ?? 'mobile').toString(),
    pairedAtMs: (json['pairedAt'] as num?)?.toInt() ?? 0,
    lastSeenAtMs: (json['lastSeenAt'] as num?)?.toInt() ?? 0,
    online: json['online'] == true,
    transport: (json['transport'] ?? '').toString(),
    remoteAddress: (json['remoteAddress'] ?? '').toString(),
  );
}

class SessionSummary {
  final String id;
  final String title;
  final String status;
  final int stepCount;
  final String lastActivity;
  final int artifactCount;
  final int updatedAtMs;
  final String workspaceHint;
  final String workspaceName;
  final bool isSubagent;

  const SessionSummary({
    required this.id,
    required this.title,
    required this.status,
    required this.stepCount,
    required this.lastActivity,
    required this.artifactCount,
    required this.updatedAtMs,
    this.workspaceHint = '',
    this.workspaceName = '',
    this.isSubagent = false,
  });

  SessionSummary copyWith({String? status, String? lastActivity, bool? isSubagent}) =>
      SessionSummary(
        id: id,
        title: title,
        status: status ?? this.status,
        stepCount: stepCount,
        lastActivity: lastActivity ?? this.lastActivity,
        artifactCount: artifactCount,
        updatedAtMs: updatedAtMs,
        workspaceHint: workspaceHint,
        workspaceName: workspaceName,
        isSubagent: isSubagent ?? this.isSubagent,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'status': status,
    'stepCount': stepCount,
    'lastActivity': lastActivity,
    'artifactCount': artifactCount,
    'updatedAtMs': updatedAtMs,
    'workspaceHint': workspaceHint,
    'workspaceName': workspaceName,
    'isSubagent': isSubagent,
  };

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    final hint = (json['workspaceHint'] ?? '').toString();
    var wsName = (json['workspaceName'] ?? '').toString();
    if (wsName.isEmpty && hint.isNotEmpty) {
      final parts = hint.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).toList();
      if (parts.isNotEmpty) wsName = parts.last;
    }
    return SessionSummary(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? 'Session').toString(),
      status: (json['status'] ?? 'idle').toString(),
      stepCount: (json['stepCount'] as num?)?.toInt() ?? 0,
      lastActivity: (json['lastActivity'] ?? '').toString(),
      artifactCount: (json['artifactCount'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      workspaceHint: hint,
      workspaceName: wsName,
      isSubagent: json['isSubagent'] == true,
    );
  }
}

class WorkspaceInfo {
  final String path;
  final String name;
  final bool isDefault;
  final bool isOpenInHost;
  final int sessionCount;

  const WorkspaceInfo({
    required this.path,
    required this.name,
    this.isDefault = false,
    this.isOpenInHost = false,
    this.sessionCount = 0,
  });

  WorkspaceInfo copyWith({
    bool? isDefault,
    bool? isOpenInHost,
    int? sessionCount,
  }) =>
      WorkspaceInfo(
        path: path,
        name: name,
        isDefault: isDefault ?? this.isDefault,
        isOpenInHost: isOpenInHost ?? this.isOpenInHost,
        sessionCount: sessionCount ?? this.sessionCount,
      );

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'isDefault': isDefault,
    'isOpenInHost': isOpenInHost,
    'sessionCount': sessionCount,
  };

  factory WorkspaceInfo.fromJson(Map<String, dynamic> json) {
    final rawPath = (json['path'] ?? '').toString();
    var rawName = (json['name'] ?? '').toString();
    if (rawName.isEmpty && rawPath.isNotEmpty) {
      final parts = rawPath.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).toList();
      if (parts.isNotEmpty) rawName = parts.last;
    }
    return WorkspaceInfo(
      path: rawPath,
      name: rawName.isEmpty ? 'workspace' : rawName,
      isDefault: json['isDefault'] == true,
      isOpenInHost: json['isOpenInHost'] == true,
      sessionCount: (json['sessionCount'] as num?)?.toInt() ?? 0,
    );
  }
}

class DiscoveredLanBridge {
  final String machineId;
  final String machineName;
  final String lanUrl;
  final String lanIp;
  final int port;
  final String source; // 'udp' | 'mdns'

  const DiscoveredLanBridge({
    required this.machineId,
    required this.machineName,
    required this.lanUrl,
    required this.lanIp,
    required this.port,
    this.source = 'udp',
  });
}

class PendingAttachment {
  final String id;
  final String fileName;
  final String savedPath;
  final String relativePath;
  final int sizeBytes;
  final bool isImage;
  final Uint8List? previewBytes;
  final bool uploading;
  final String? error;

  const PendingAttachment({
    required this.id,
    required this.fileName,
    this.savedPath = '',
    this.relativePath = '',
    required this.sizeBytes,
    required this.isImage,
    this.previewBytes,
    this.uploading = false,
    this.error,
  });

  PendingAttachment copyWith({
    String? savedPath,
    String? relativePath,
    bool? isImage,
    bool? uploading,
    String? error,
    bool clearError = false,
  }) {
    return PendingAttachment(
      id: id,
      fileName: fileName,
      savedPath: savedPath ?? this.savedPath,
      relativePath: relativePath ?? this.relativePath,
      sizeBytes: sizeBytes,
      isImage: isImage ?? this.isImage,
      previewBytes: previewBytes,
      uploading: uploading ?? this.uploading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ToolCallInfo {
  final String name;
  final String summary;
  final String? artifactFileName;
  final String? artifactSummary;

  const ToolCallInfo({
    required this.name,
    required this.summary,
    this.artifactFileName,
    this.artifactSummary,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'summary': summary,
    if (artifactFileName != null) 'artifactFileName': artifactFileName,
    if (artifactSummary != null) 'artifactSummary': artifactSummary,
  };

  factory ToolCallInfo.fromJson(Map<String, dynamic> json) {
    final artFile = json['artifactFileName']?.toString().trim();
    final artSum = json['artifactSummary']?.toString().trim();
    return ToolCallInfo(
      name: (json['name'] ?? 'tool').toString(),
      summary: (json['summary'] ?? json['name'] ?? 'Tool').toString(),
      artifactFileName: (artFile != null && artFile.isNotEmpty) ? artFile : null,
      artifactSummary: (artSum != null && artSum.isNotEmpty) ? artSum : null,
    );
  }
}

class AgentStep {
  static const int optimisticStepIndex = 999999;

  final int seq;
  final int stepIndex;
  final String role;
  final String status;
  final String source;
  final String thinking;
  final String content;
  final List<ToolCallInfo> toolCalls;

  const AgentStep({
    int? seq,
    required this.stepIndex,
    required this.role,
    required this.status,
    this.source = '',
    required this.thinking,
    required this.content,
    required this.toolCalls,
  }) : seq = seq ?? stepIndex;

  bool get isOptimistic => stepIndex == optimisticStepIndex;

  AgentStep copyWith({String? status}) => AgentStep(
    seq: seq,
    stepIndex: stepIndex,
    role: role,
    status: status ?? this.status,
    source: source,
    thinking: thinking,
    content: content,
    toolCalls: toolCalls,
  );

  Map<String, dynamic> toJson() => {
    'seq': seq,
    'stepIndex': stepIndex,
    'role': role,
    'status': status,
    'source': source,
    'thinking': thinking,
    'content': content,
    'toolCalls': toolCalls.map((t) => t.toJson()).toList(),
  };

  factory AgentStep.fromJson(Map<String, dynamic> json) {
    final rawTools = json['toolCalls'];
    final tools = rawTools is List
        ? rawTools
              .whereType<Map>()
              .map((e) => ToolCallInfo.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : <ToolCallInfo>[];
    final stepIdx = (json['stepIndex'] as num?)?.toInt() ?? 0;
    final seqVal = (json['seq'] as num?)?.toInt() ?? stepIdx;
    return AgentStep(
      seq: seqVal,
      stepIndex: stepIdx,
      role: (json['role'] ?? 'assistant').toString(),
      status: (json['status'] ?? 'DONE').toString(),
      source: (json['source'] ?? '').toString(),
      thinking: (json['thinking'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      toolCalls: tools,
    );
  }
}

class ArtifactInfo {
  final String fileName;
  final int sizeBytes;

  const ArtifactInfo({required this.fileName, required this.sizeBytes});

  Map<String, dynamic> toJson() => {'fileName': fileName, 'sizeBytes': sizeBytes};

  factory ArtifactInfo.fromJson(Map<String, dynamic> json) => ArtifactInfo(
    fileName: (json['fileName'] ?? '').toString(),
    sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
  );
}

class ApprovalRequest {
  final String id;
  final String conversationId;
  final String toolName;
  final String summary;
  final String commandLine;
  final String cwd;
  final int createdAtMs;
  final int expiresAtMs;

  const ApprovalRequest({
    required this.id,
    required this.conversationId,
    required this.toolName,
    required this.summary,
    required this.commandLine,
    required this.cwd,
    this.createdAtMs = 0,
    required this.expiresAtMs,
  });

  int get totalDurationMs =>
      createdAtMs > 0 ? (expiresAtMs - createdAtMs).clamp(5000, 300000) : 45000;

  factory ApprovalRequest.fromJson(Map<String, dynamic> json) {
    final args = json['args'] is Map ? Map<String, dynamic>.from(json['args'] as Map) : const {};
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final created = (json['createdAt'] as num?)?.toInt() ?? nowMs;
    return ApprovalRequest(
      id: (json['id'] ?? '').toString(),
      conversationId: (json['conversationId'] ?? '').toString(),
      toolName: (json['toolName'] ?? 'tool').toString(),
      summary: (json['summary'] ?? '').toString(),
      commandLine: (args['CommandLine'] ?? args['Path'] ?? json['summary'] ?? '').toString(),
      cwd: (json['cwd'] ?? '').toString(),
      createdAtMs: created,
      expiresAtMs: (json['expiresAt'] as num?)?.toInt() ?? (nowMs + 45000),
    );
  }
}

class GitFileChange {
  final String status;
  final String path;

  const GitFileChange({required this.status, required this.path});

  factory GitFileChange.fromJson(Map<String, dynamic> json) => GitFileChange(
    status: (json['status'] ?? 'M').toString(),
    path: (json['path'] ?? '').toString(),
  );
}

class PendingFileChange {
  final String path;
  final String status; // 'NEW' | 'MOD' | 'DEL'
  final int additions;
  final int deletions;
  final String conversationId;
  final int updatedAtMs;

  const PendingFileChange({
    required this.path,
    required this.status,
    required this.additions,
    required this.deletions,
    required this.conversationId,
    required this.updatedAtMs,
  });

  factory PendingFileChange.fromJson(Map<String, dynamic> json) => PendingFileChange(
    path: (json['path'] ?? '').toString(),
    status: (json['status'] ?? 'MOD').toString(),
    additions: (json['additions'] as num?)?.toInt() ?? 0,
    deletions: (json['deletions'] as num?)?.toInt() ?? 0,
    conversationId: (json['conversationId'] ?? '').toString(),
    updatedAtMs: (json['updatedAt'] as num?)?.toInt() ?? 0,
  );
}
