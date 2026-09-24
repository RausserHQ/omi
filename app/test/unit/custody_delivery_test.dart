import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/services/wals/custody_delivery.dart';
import 'package:omi/services/wals/local_wal_sync.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/services/wals/wal.dart';

class _Listener implements IWalSyncListener {
  @override
  void onWalUpdated() {}
  @override
  void onWalSynced(Wal wal, {ServerConversation? conversation}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late HttpServer server;
  late Wal wal;
  late List<Wal> disk;
  late List<String> uploads;
  var status = 503;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('custody_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
    wal = Wal(timerStart: 1700000000, codec: BleAudioCodec.opus, seconds: 30,
        storage: WalStorage.disk, status: WalStatus.synced, filePath: 'audio.bin');
    await File('${dir.path}/audio.bin').writeAsBytes([2, 0, 0, 0, 1, 2]);
    disk = [Wal.fromJson(wal.toJson())];
    uploads = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(request.uri.path, '/v1/uploads');
      expect(request.headers.value('x-audio-format'), 'opus');
      expect(request.headers.contentType?.mimeType, 'application/octet-stream');
      expect(request.headers.contentLength, bytes.length);
      expect(request.headers.value('x-captured-at'), '2023-11-14T22:13:20.000Z');
      expect(bytes, [2, 0, 0, 0, 1, 2]);
      final id = request.headers.value('x-upload-id')!;
      uploads.add(id);
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'upload_id': id, 'status': status == 201 ? 'stored' : 'duplicate'}));
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'), null);
    await dir.delete(recursive: true);
  });

  CustodyDelivery delivery(Future<List<Wal>> Function() load, Future<void> Function() save, int port) =>
      CustodyDelivery(load: load, save: save, endpoint: 'http://127.0.0.1:$port/v1/uploads', allowLoopbackForTest: true);

  test('retry after restart keeps ID and source until acknowledgement; ACK suppresses replay', () async {
    Future<void> save() async { disk = [Wal.fromJson(wal.toJson())]; }
    final first = delivery(() async => [wal], save, server.port);
    await first.drain();
    expect(wal.custodyDelivered, false);
    expect(disk.single.custodyUploadId, uploads.single);
    expect(await File('${dir.path}/audio.bin').exists(), true);

    status = 201;
    wal = Wal.fromJson(disk.single.toJson());
    final restarted = delivery(() async => [wal], save, server.port);
    await restarted.drain();
    expect(uploads, [uploads.first, uploads.first]);
    expect(disk.single.custodyDelivered, true);
    await restarted.drain();
    expect(uploads.length, 2);
    expect(await File('${dir.path}/audio.bin').exists(), true);
  });

  test('failed index persistence prevents sending before the ID is durable', () async {
    final tracer = delivery(() async => [wal], () async => throw StateError('disk full'), server.port);
    await tracer.drain();
    expect(uploads, isEmpty);
    expect(wal.custodyUploadId, isNull);
    expect(await File('${dir.path}/audio.bin').exists(), true);
  });

  test('a response without matching ACK never marks delivered', () async {
    status = 409;
    final tracer = delivery(() async => [wal], () async {}, server.port);
    await tracer.drain();
    expect(wal.custodyDelivered, false);
    expect(wal.custodyRejected, true);
    await tracer.drain();
    expect(uploads.length, 1);
  });

  test('PCM WAL framing is removed before raw PCM upload', () {
    wal.codec = BleAudioCodec.pcm16;
    expect(custodyPayload(wal, Uint8List.fromList([2, 0, 0, 0, 1, 2, 2, 0, 0, 0, 3, 4])), [1, 2, 3, 4]);
    expect(custodyPayload(wal, Uint8List.fromList([9, 0, 0, 0, 1])), isEmpty);
  });

  test('local WAL deletion waits for custody ACK when enabled', () async {
    final tracer = delivery(() async => [wal], () async {}, server.port);
    final sync = LocalWalSyncImpl(_Listener(), custodyDelivery: tracer);
    sync.testWals = [wal];
    await sync.deleteWal(wal);
    expect(await File('${dir.path}/audio.bin').exists(), true);
    expect(sync.testWals, contains(wal));
    wal.custodyDelivered = true;
    await sync.deleteWal(wal);
    expect(await File('${dir.path}/audio.bin').exists(), false);
  });

  test('ordinary builds cannot send audio to the private receiver', () {
    expect(CustodyDelivery(load: () async => [wal], save: () async {}).enabled, false);
  });
}
