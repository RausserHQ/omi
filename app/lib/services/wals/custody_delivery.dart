import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:uuid/uuid.dart';

const custodyEndpoint = String.fromEnvironment('OMI_CUSTODY_ENDPOINT');

/// Opt-in delivery of persisted WAL audio, independent of normal Omi sync.
class CustodyDelivery {
  CustodyDelivery({
    required this.load,
    required this.save,
    this.endpoint = custodyEndpoint,
    this.allowLoopbackForTest = false,
  });

  final Future<List<Wal>> Function() load;
  final Future<void> Function() save;
  final String endpoint;
  @visibleForTesting
  final bool allowLoopbackForTest;
  Timer? _timer;
  bool _draining = false;
  bool _stopped = false;

  bool get enabled {
    final uri = Uri.tryParse(endpoint);
    return uri != null &&
        uri.host.isNotEmpty &&
        uri.path == '/v1/uploads' &&
        uri.userInfo.isEmpty &&
        uri.query.isEmpty &&
        uri.fragment.isEmpty &&
        (uri.scheme == 'https' || allowLoopbackForTest && uri.scheme == 'http' && uri.host == '127.0.0.1');
  }

  void start() {
    if (!enabled) return;
    _stopped = false;
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => schedule());
    schedule();
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  void schedule() {
    if (!enabled || _stopped || _draining) return;
    unawaited(drain());
  }

  Future<void> drain() async {
    if (!enabled || _stopped || _draining) return;
    _draining = true;
    try {
      for (final wal in await load()) {
        if (_stopped) break;
        if (wal.storage != WalStorage.disk || wal.custodyDelivered || wal.custodyRejected || wal.filePath == null ||
            wal.codec != BleAudioCodec.opus && wal.codec != BleAudioCodec.opusFS320 && wal.codec != BleAudioCodec.pcm16) {
          continue;
        }
        try {
          final path = await Wal.getFilePath(wal.filePath);
          if (path == null) continue;
          final file = File(path);
          if (!await file.exists()) continue;
          final payload = custodyPayload(wal, await file.readAsBytes());
          if (payload.isEmpty || payload.length > 16 * 1024 * 1024) continue;
          if (wal.custodyUploadId == null) {
            wal.custodyUploadId = const Uuid().v4();
            try {
              await save();
            } catch (_) {
              wal.custodyUploadId = null;
              rethrow;
            }
          }
          final result = await _upload(wal, payload);
          if (result == 400 || result == 409) {
            wal.custodyRejected = true;
            await save();
          } else if ((result == 200 || result == 201) && !_stopped) {
            wal.custodyDelivered = true;
            try {
              await save();
            } catch (_) {
              wal.custodyDelivered = false;
              rethrow;
            }
          }
        } catch (_) {
          // Failed delivery leaves the local recording pending for the next scan.
        }
      }
    } catch (_) {
      // Startup can race WAL initialization; retry on the next tick.
    } finally {
      _draining = false;
    }
  }

  Future<int> _upload(Wal wal, Uint8List payload) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..autoUncompress = false;
    try {
      final request = await client.postUrl(Uri.parse(endpoint)).timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.binary;
      request.headers.set('X-Upload-Id', wal.custodyUploadId!);
      request.headers.set(
        'X-Captured-At',
        DateTime.fromMillisecondsSinceEpoch(wal.timerStart * 1000, isUtc: true).toIso8601String(),
      );
      request.headers.set('X-Audio-Format', wal.codec == BleAudioCodec.pcm16 ? 'pcm16' : 'opus');
      if (wal.codec == BleAudioCodec.pcm16) {
        request.headers.set('X-Sample-Rate', wal.sampleRate);
        request.headers.set('X-Channels', wal.channel);
      }
      request.contentLength = payload.length;
      request.add(payload);
      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 && response.statusCode != 201) return response.statusCode;
      final ack = jsonDecode(body);
      if (ack is Map && ack['upload_id'] == wal.custodyUploadId &&
          (response.statusCode == 200 ? ack['status'] == 'duplicate' : ack['status'] == 'stored')) {
        return response.statusCode;
      }
      return 0;
    } finally {
      client.close(force: true);
    }
  }
}

/// WAL files contain little-endian length-prefixed frames. Opus remains framed;
/// PCM is unframed to satisfy the receiver's raw pcm16 contract.
Uint8List custodyPayload(Wal wal, Uint8List bytes) {
  if (wal.codec != BleAudioCodec.pcm16) return bytes;
  final frames = <Uint8List>[];
  var offset = 0;
  var total = 0;
  while (offset + 4 <= bytes.length) {
    final length = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.little);
    offset += 4;
    if (length == 0 || length > bytes.length - offset) return Uint8List(0);
    frames.add(Uint8List.sublistView(bytes, offset, offset + length));
    total += length;
    offset += length;
  }
  if (offset != bytes.length || total.isOdd) return Uint8List(0);
  final result = Uint8List(total);
  offset = 0;
  for (final frame in frames) {
    result.setRange(offset, offset + frame.length, frame);
    offset += frame.length;
  }
  return result;
}
