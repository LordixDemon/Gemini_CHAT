import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/remote_models.dart';

/// Bounded local cache for instant 0ms cold launch and full offline reading of
/// sessions, steps, workspaces, pinned sessions, and Markdown plan artifacts.
class OfflineCacheService {
  static const String _pinnedKey = 'agy_cache_pinned_sessions_v1';
  static const String _machinePrefix = 'agy_cache_machine_v1_';
  static const String _detailLruKey = 'agy_cache_detail_lru_v1';
  static const String _detailPrefix = 'agy_cache_detail_v1_';
  static const String _artifactLruKey = 'agy_cache_artifact_lru_v1';
  static const String _artifactPrefix = 'agy_cache_artifact_v1_';

  static const int maxCachedSessions = 18;
  static const int maxStepsPerCachedSession = 120;
  static const int maxCachedArtifacts = 30;
  static const int maxArtifactChars = 260000;

  final Map<String, String> _searchPreviewBySession = {};

  Future<Set<String>> loadPinnedSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_pinnedKey) ?? const <String>[];
    return list.where((s) => s.isNotEmpty).toSet();
  }

  Future<void> savePinnedSessions(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_pinnedKey, ids.toList());
  }

  Future<({List<SessionSummary> sessions, List<WorkspaceInfo> workspaces, String activeWorkspace})>
      loadMachineSnapshot(String machineId) async {
    if (machineId.isEmpty) {
      return (
        sessions: const <SessionSummary>[],
        workspaces: const <WorkspaceInfo>[],
        activeWorkspace: '',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_machinePrefix$machineId');
    if (raw == null || raw.isEmpty) {
      return (
        sessions: const <SessionSummary>[],
        workspaces: const <WorkspaceInfo>[],
        activeWorkspace: '',
      );
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final sessions = (map['sessions'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => SessionSummary.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final workspaces = (map['workspaces'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => WorkspaceInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final activeWs = (map['activeWorkspace'] ?? '').toString();
      return (sessions: sessions, workspaces: workspaces, activeWorkspace: activeWs);
    } catch (_) {
      return (
        sessions: const <SessionSummary>[],
        workspaces: const <WorkspaceInfo>[],
        activeWorkspace: '',
      );
    }
  }

  Future<void> saveMachineSnapshot({
    required String machineId,
    required List<SessionSummary> sessions,
    required List<WorkspaceInfo> workspaces,
    required String activeWorkspace,
  }) async {
    if (machineId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode({
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      'activeWorkspace': activeWorkspace,
      'sessions': sessions.take(60).map((s) => s.toJson()).toList(),
      'workspaces': workspaces.take(25).map((w) => w.toJson()).toList(),
    });
    await prefs.setString('$_machinePrefix$machineId', payload);
  }

  Future<({List<AgentStep> steps, List<ArtifactInfo> artifacts})?> loadSessionDetail(
    String conversationId,
  ) async {
    if (conversationId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_detailPrefix$conversationId');
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final steps = (map['steps'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => AgentStep.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final artifacts = (map['artifacts'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => ArtifactInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      _indexSessionSearchPreview(conversationId, steps);
      return (steps: steps, artifacts: artifacts);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSessionDetail({
    required String conversationId,
    required List<AgentStep> steps,
    required List<ArtifactInfo> artifacts,
  }) async {
    if (conversationId.isEmpty) return;
    final persistedSteps = steps
        .where((s) => s.stepIndex != 999999)
        .toList();
    final tail = persistedSteps.length > maxStepsPerCachedSession
        ? persistedSteps.sublist(persistedSteps.length - maxStepsPerCachedSession)
        : persistedSteps;
    _indexSessionSearchPreview(conversationId, tail);

    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode({
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      'steps': tail.map((s) => s.toJson()).toList(),
      'artifacts': artifacts.map((a) => a.toJson()).toList(),
    });
    await prefs.setString('$_detailPrefix$conversationId', raw);

    final lru = (prefs.getStringList(_detailLruKey) ?? <String>[]).toList();
    lru.remove(conversationId);
    lru.insert(0, conversationId);
    while (lru.length > maxCachedSessions) {
      final evicted = lru.removeLast();
      _searchPreviewBySession.remove(evicted);
      await prefs.remove('$_detailPrefix$evicted');
    }
    await prefs.setStringList(_detailLruKey, lru);
  }

  Future<void> warmSearchIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final lru = prefs.getStringList(_detailLruKey) ?? const <String>[];
    for (final convId in lru) {
      if (_searchPreviewBySession.containsKey(convId)) continue;
      await loadSessionDetail(convId);
    }
  }

  bool hasCachedDetailSync(String conversationId) =>
      _searchPreviewBySession.containsKey(conversationId);

  String getCachedSearchText(String conversationId) =>
      _searchPreviewBySession[conversationId] ?? '';

  void _indexSessionSearchPreview(String conversationId, List<AgentStep> steps) {
    final buf = StringBuffer();
    final start = steps.length > 24 ? steps.length - 24 : 0;
    for (var i = start; i < steps.length; i++) {
      final content = steps[i].content.trim();
      if (content.isEmpty) continue;
      buf.write(content.length > 400 ? content.substring(0, 400) : content);
      buf.write(' ');
    }
    _searchPreviewBySession[conversationId] = buf.toString().toLowerCase();
  }

  Future<String?> loadArtifactMarkdown(String conversationId, String fileName) async {
    if (conversationId.isEmpty || fileName.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_artifactPrefix$conversationId::$fileName');
  }

  Future<void> saveArtifactMarkdown(
    String conversationId,
    String fileName,
    String content,
  ) async {
    if (conversationId.isEmpty || fileName.isEmpty || content.isEmpty) return;
    final keyId = '$conversationId::$fileName';
    final clipped =
        content.length > maxArtifactChars ? content.substring(0, maxArtifactChars) : content;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_artifactPrefix$keyId', clipped);

    final lru = (prefs.getStringList(_artifactLruKey) ?? <String>[]).toList();
    lru.remove(keyId);
    lru.insert(0, keyId);
    while (lru.length > maxCachedArtifacts) {
      final evicted = lru.removeLast();
      await prefs.remove('$_artifactPrefix$evicted');
    }
    await prefs.setStringList(_artifactLruKey, lru);
  }
}
