import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

enum ConnectionPhase { disconnected, connecting, connected }

/// Converts an `http://` or `https://` Bridge base URL into its `ws://` or `wss://` counterpart.
String httpToWsBaseUrl(String baseUrl) {
  return baseUrl
      .trim()
      .replaceAll(RegExp(r'/+$'), '')
      .replaceFirst(RegExp(r'^http:'), 'ws:')
      .replaceFirst(RegExp(r'^https:'), 'wss:');
}

/// Transport abstraction decoupling `BridgeController` from concrete WebSocket I/O.
abstract interface class RpcSocketTransport {
  Future<void> get ready;
  Stream<dynamic> get stream;
  void send(String data);
  Future<void> close();
}

/// Default production WebSocket transport backed by `package:web_socket_channel`.
class WebSocketRpcTransport implements RpcSocketTransport {
  final WebSocketChannel _channel;

  WebSocketRpcTransport(Uri uri) : _channel = WebSocketChannel.connect(uri) {
    // Prevent unhandled async WebSocketChannelException if TCP handshake times out
    // or socket is closed while connecting.
    _channel.ready.then<void>((_) {}, onError: (_) {});
  }

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close();
}

/// Tracks an outbound mobile prompt awaiting server acknowledgement or reconnect replay.
class PendingOutboundPrompt {
  final String reqId;
  final String? conversationId;
  final String prompt;
  final String? workspace;
  final int? optimisticSeq;
  bool sentOnCurrentSocket = false;
  Timer? ackTimer;

  PendingOutboundPrompt({
    required this.reqId,
    required this.conversationId,
    required this.prompt,
    this.workspace,
    required this.optimisticSeq,
  });
}
