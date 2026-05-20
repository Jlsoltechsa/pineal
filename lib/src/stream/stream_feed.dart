import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'stream_buffer.dart';

/// Pumps a Dart [Stream] (or a SendPort feed from an [Isolate]) into a
/// [StreamBuffer] without blocking the UI thread.
///
/// Three constructors:
/// - [StreamFeed.values]: subscribes to a `Stream<double>` and calls
///   [StreamBuffer.push] on each event.
/// - [StreamFeed.batches]: subscribes to a `Stream<Float32List>` and calls
///   [StreamBuffer.pushAll] — the preferred path for high-frequency sources
///   since it lets the batch become one `setRange` memcpy.
/// - [StreamFeed.isolatePort]: spawns a [ReceivePort] and accepts payloads
///   coming from a worker isolate. Payloads can be `double` or
///   `Float32List`.
class StreamFeed {
  StreamFeed.values(this.buffer, Stream<double> source) {
    _sub = source.listen(buffer.push, onError: _onError);
  }

  StreamFeed.batches(this.buffer, Stream<Float32List> source) {
    _sub = source.listen(buffer.pushAll, onError: _onError);
  }

  /// Bidirectional channel rooted in the UI isolate. The returned
  /// [SendPort] can be shipped to a worker isolate so it can post samples
  /// back. Cancel by calling [dispose].
  factory StreamFeed.isolatePort(StreamBuffer buffer) {
    final port = ReceivePort();
    final feed = StreamFeed._raw(buffer);
    feed._port = port;
    feed._sub = port.listen((msg) {
      if (msg is Float32List) {
        buffer.pushAll(msg);
      } else if (msg is double) {
        buffer.push(msg);
      } else if (msg is List<double>) {
        // Convenience for closures that emit native lists.
        final tl = Float32List(msg.length);
        for (var i = 0; i < msg.length; i++) {
          tl[i] = msg[i];
        }
        buffer.pushAll(tl);
      }
    });
    return feed;
  }

  StreamFeed._raw(this.buffer);

  final StreamBuffer buffer;
  StreamSubscription<Object?>? _sub;
  ReceivePort? _port;

  /// Available only when constructed via [StreamFeed.isolatePort]. Pass
  /// this to your worker isolate so it can `send` samples back.
  SendPort? get sendPort => _port?.sendPort;

  Object? _lastError;
  Object? get lastError => _lastError;

  void _onError(Object error, StackTrace stack) {
    _lastError = error;
  }

  void pause() => _sub?.pause();
  void resume() => _sub?.resume();

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _port?.close();
    _port = null;
  }
}
