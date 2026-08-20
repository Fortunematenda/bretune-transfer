import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:bonsoir/bonsoir.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'sendable_file.dart';

typedef OfferHandler = Future<bool> Function(PendingOffer offer);

class TransferService {
  TransferService({required this.onChanged, required this.onOffer});
  final void Function() onChanged;
  final OfferHandler onOffer;
  final devices = <String, NearbyDevice>{};
  final transfers = <TransferRecord>[];
  final destinations = <Destination>[];
  final _accepted = <String, PendingOffer>{};
  final _uuid = const Uuid();
  HttpServer? _server;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  late String deviceId;
  late String deviceName;
  late String deviceSecret;
  late String pairingPin;
  final _peerSecrets = <String, String>{};
  bool autoAcceptFromPaired = true;
  String? _broadcastHost;
  int? _broadcastPort;

  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    deviceId = prefs.getString('deviceId') ?? _uuid.v4();
    await prefs.setString('deviceId', deviceId);
    deviceName = await _resolveDeviceName(prefs);
    await prefs.setString('deviceName', deviceName);
    deviceSecret = prefs.getString('deviceSecret') ?? _uuid.v4();
    await prefs.setString('deviceSecret', deviceSecret);
    pairingPin = (100000 + DateTime.now().microsecondsSinceEpoch % 900000).toString();
    autoAcceptFromPaired = prefs.getBool('autoAcceptFromPaired') ?? true;
    for (final key in prefs.getKeys().where((k) => k.startsWith('peerSecret:'))) {
      _peerSecrets[key.substring('peerSecret:'.length)] = prefs.getString(key)!;
    }
    await _loadTransfers();
    await _loadDestinations();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: true);
    _server!.listen(_handleRequest);
    final localIp = await _localIPv4();
    _broadcastHost = localIp;
    _broadcastPort = _server!.port;
    final service = BonsoirService(
      name: 'Bretune-$deviceId',
      type: '_bretunetransfer._tcp',
      port: _server!.port,
      attributes: {
        'id': deviceId,
        'name': deviceName,
        'platform': platformLabel(),
        if (localIp != null) 'ip': localIp,
      },
    );
    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.initialize();
    await _broadcast!.start();
    _discovery = BonsoirDiscovery(type: '_bretunetransfer._tcp');
    await _discovery!.initialize();
    _discovery!.eventStream!.listen(_discoveryEvent);
    await _discovery!.start();
  }

  Future<void> _loadDestinations() async {
    final docs = await getApplicationDocumentsDirectory();
    final inbox = Directory(p.join(docs.path, 'Bretune Transfer'));
    await inbox.create(recursive: true);
    destinations
      ..clear()
      ..add(Destination('inbox', 'Bretune Inbox', inbox.path));
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'];
      if (profile != null) {
        destinations.addAll([Destination('documents', 'Documents', p.join(profile, 'Documents')), Destination('downloads', 'Downloads', p.join(profile, 'Downloads')), Destination('desktop', 'Desktop', p.join(profile, 'Desktop'))]);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    var custom = prefs.getString('customDestination');
    if (custom != null && custom.isNotEmpty) {
      if (Platform.isAndroid) {
        final resolved = await _resolveWritableReceivePath(custom);
        if (resolved != custom) {
          custom = resolved;
          await prefs.setString('customDestination', resolved);
        }
      }
      destinations.add(Destination('custom', 'My selected folder', custom));
    }
  }

  Future<String> setCustomDestination(String path) async {
    if (Platform.isAndroid) {
      path = await _resolveWritableReceivePath(path);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('customDestination', path);
    await _loadDestinations();
    onChanged();
    return path;
  }

  Future<String> _resolveWritableReceivePath(String picked) async {
    try {
      final probe = File(p.join(picked, '.bretune_write_test'));
      await probe.writeAsString('ok');
      await probe.delete();
      return picked;
    } catch (_) {
      final docs = await getApplicationDocumentsDirectory();
      final folderName = p.basename(picked).isEmpty ? 'Received' : p.basename(picked);
      final fallback = p.join(docs.path, 'Bretune Transfer', folderName);
      await Directory(fallback).create(recursive: true);
      return fallback;
    }
  }

  Future<void> setAutoAcceptFromPaired(bool value) async {
    autoAcceptFromPaired = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoAcceptFromPaired', value);
    onChanged();
  }

  Future<String> _resolveDeviceName(SharedPreferences prefs) async {
    final saved = prefs.getString('deviceName');
    if (!isGenericDeviceName(saved)) return saved!.trim();

    if (Platform.isAndroid) {
      try {
        final host = (await File('/proc/sys/kernel/hostname').readAsString()).trim();
        if (!isGenericDeviceName(host)) return host;
      } catch (_) {}
      try {
        final result = await Process.run('getprop', ['ro.product.model']);
        final model = '${result.stdout}'.trim();
        if (!isGenericDeviceName(model)) return model;
      } catch (_) {}
      return displayDeviceName(fallbackPlatform: 'Android', fallbackId: deviceId);
    }

    final host = Platform.localHostname.trim();
    if (!isGenericDeviceName(host)) return host;
    return displayDeviceName(fallbackPlatform: platformLabel(), fallbackId: deviceId);
  }

  void _discoveryEvent(BonsoirDiscoveryEvent event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent(:final service):
        service.resolve(_discovery!.serviceResolver);
      case BonsoirDiscoveryServiceResolvedEvent(:final service):
      case BonsoirDiscoveryServiceUpdatedEvent(:final service):
        unawaited(_registerDiscoveredService(service));
      case BonsoirDiscoveryServiceLostEvent(:final service):
        final id = service.attributes['id'];
        if (id != null) devices.remove(id);
        onChanged();
      default:
        break;
    }
  }

  Future<void> _registerDiscoveredService(BonsoirService service) async {
    final id = service.attributes['id'];
    if (id == null || id == deviceId) return;
    final host = await _resolveConnectHost(service);
    if (host == null) return;
    devices[id] = NearbyDevice(
      id: id,
      name: displayDeviceName(
        preferred: service.attributes['name'],
        fallbackPlatform: service.attributes['platform'],
        fallbackId: id,
      ),
      host: host,
      port: service.port,
      platform: service.attributes['platform'] ?? 'Device',
    );
    onChanged();
  }

  Future<String?> _localIPv4() async {
    try {
      for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false)) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return address.address;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _resolveConnectHost(BonsoirService service) async {
    final attributeIp = service.attributes['ip'];
    if (_isIPv4(attributeIp)) return attributeIp;

    final host = service.host;
    if (host == null || host.isEmpty) return attributeIp;

    if (_isIPv4(host)) return host;
    if (host == 'localhost' || host == '127.0.0.1') return attributeIp ?? host;

    try {
      final resolved = await InternetAddress.lookup(host).timeout(const Duration(seconds: 4));
      for (final address in resolved) {
        if (address.type == InternetAddressType.IPv4 && !address.isLoopback) {
          return address.address;
        }
      }
    } catch (_) {}

    return _isIPv4(attributeIp) ? attributeIp : host;
  }

  bool _isIPv4(String? value) {
    if (value == null || value.isEmpty) return false;
    return InternetAddress.tryParse(value)?.type == InternetAddressType.IPv4;
  }

  Future<List<Destination>> fetchDestinations(NearbyDevice device) async {
    final response = await http.get(device.uri('/v1/destinations'), headers: _authHeaders(device)).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) throw Exception('Could not read destination folders');
    return (jsonDecode(response.body) as List).map((e) => Destination.fromJson(e)).toList();
  }

  bool isPaired(NearbyDevice device) => _peerSecrets.containsKey(device.id);
  String get qrPayload => jsonEncode({
    'app': 'BretuneTransfer',
    'version': 1,
    'deviceId': deviceId,
    'name': deviceName,
    'secret': deviceSecret,
    'platform': platformLabel(),
    if (_broadcastHost != null) 'host': _broadcastHost,
    if (_broadcastPort != null) 'port': _broadcastPort,
  });

  Map<String, String> _authHeaders(NearbyDevice device) => {'x-bretune-key': _peerSecrets[device.id] ?? ''};

  Future<String?> pairWithPin(NearbyDevice device, String pin) async {
    try {
      final response = await http
          .post(
            device.uri('/v1/pair'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'deviceId': deviceId, 'pin': pin, 'secret': deviceSecret, 'name': deviceName}),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 403) return 'Incorrect PIN. Check the code on the other device Settings screen.';
      if (response.statusCode != 200) return 'Pairing failed (${response.statusCode}).';
      final secret = jsonDecode(response.body)['secret'] as String;
      await _savePeer(device.id, secret);
      return null;
    } catch (e) {
      return 'Could not reach ${device.name}. Allow Bretune Transfer through Windows Firewall and make sure both devices are on the same Wi-Fi.';
    }
  }

  Future<String?> pairWithQr(String payload) async {
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      if (data['app'] != 'BretuneTransfer' || data['deviceId'] == null || data['secret'] == null) {
        return 'This is not a Bretune Transfer pairing code.';
      }
      final id = data['deviceId'] as String;
      if (id == deviceId) return 'You cannot pair with this device.';

      await _savePeer(id, data['secret'] as String);

      final host = data['host'] as String?;
      final port = data['port'];
      final name = displayDeviceName(
        preferred: data['name'] as String?,
        fallbackPlatform: data['platform'] as String?,
        fallbackId: id,
      );
      final platform = data['platform'] as String? ?? 'Device';
      final resolvedHost = _isIPv4(host) ? host! : devices[id]?.host ?? host ?? '';
      final resolvedPort = port is int && port > 0 ? port : devices[id]?.port ?? 0;

      if (resolvedHost.isNotEmpty && resolvedPort > 0) {
        devices[id] = NearbyDevice(id: id, name: name, host: resolvedHost, port: resolvedPort, platform: platform);
        onChanged();
      } else if (devices.containsKey(id)) {
        final existing = devices[id]!;
        devices[id] = NearbyDevice(id: id, name: name, host: existing.host, port: existing.port, platform: platform);
        onChanged();
      }

      return null;
    } catch (_) {
      return 'Could not read QR code.';
    }
  }

  Future<void> _savePeer(String id, String secret) async {
    _peerSecrets[id] = secret;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('peerSecret:$id', secret);
    onChanged();
  }

  Future<void> _loadTransfers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('transferHistory') ?? [];
    transfers
      ..clear()
      ..addAll(raw.map((entry) => TransferRecord.fromJson(jsonDecode(entry) as Map<String, dynamic>)));
    for (final record in transfers) {
      if (record.state == TransferState.sending || record.state == TransferState.receiving || record.state == TransferState.waiting) {
        record.state = TransferState.failed;
        record.message = record.message.isEmpty ? 'Interrupted before completion' : record.message;
        record.finishedAt ??= DateTime.now();
      }
    }
  }

  Future<void> _persistTransfers() async {
    final prefs = await SharedPreferences.getInstance();
    final items = transfers.take(100).map((record) => jsonEncode(record.toJson())).toList();
    await prefs.setStringList('transferHistory', items);
  }

  void _syncTransfers() {
    onChanged();
    unawaited(_persistTransfers());
  }

  void _finishRecord(TransferRecord record, TransferState state, {String message = ''}) {
    record.state = state;
    if (message.isNotEmpty) record.message = message;
    record.finishedAt = DateTime.now();
    _syncTransfers();
  }

  Future<String?> resendTransfer(TransferRecord record) async {
    if (!record.canResend) return 'This transfer cannot be resent.';
    final device = devices[record.peerDeviceId];
    if (device == null) return '${record.peer} is not online. Open Bretune Transfer on that device.';
    if (!isPaired(device)) return 'Pair with ${record.peer} again before resending.';
    final file = File(record.filePath!);
    if (!await canReadFile(file)) return 'Original file is no longer accessible. Pick it again and send.';
    final destination = Destination(record.destinationId!, record.destinationLabel ?? record.destinationId!, '');
    await sendFile(device, file, destination);
    return null;
  }

  Future<void> sendPlatformFile(NearbyDevice device, PlatformFile picked, Destination destination, {String relativePath = ''}) async {
    final file = await materializeSendableFile(picked);
    await sendFile(
      device,
      file,
      destination,
      relativePath: relativePath,
      displayName: picked.name,
    );
  }

  Future<int> sendDirectory(NearbyDevice device, String directoryPath, Destination destination) async {
    final root = Directory(directoryPath);
    if (!await root.exists()) throw Exception('Folder not found.');

    try {
      var count = 0;
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relative = p.relative(entity.path, from: directoryPath);
        final folderPart = p.dirname(relative);
        final rel = folderPart == '.' ? '' : folderPart;
        await sendFile(device, entity, destination, relativePath: rel);
        count++;
      }
      return count;
    } on FileSystemException catch (e) {
      throw Exception('Cannot read that folder on this device. Try sending files instead. (${e.message})');
    }
  }

  Future<void> sendFile(
    NearbyDevice device,
    File file,
    Destination destination, {
    String relativePath = '',
    String? displayName,
  }) async {
    if (!await canReadFile(file)) {
      throw Exception('Cannot read ${displayName ?? p.basename(file.path)}');
    }
    final fileName = displayName ?? p.basename(file.path);
    final length = await file.length();
    final hash = await sha256.bind(file.openRead()).first;
    final id = _uuid.v4();
    final record = TransferRecord(
      id: id,
      fileName: fileName,
      peer: device.name,
      peerDeviceId: device.id,
      total: length,
      incoming: false,
      state: TransferState.waiting,
      filePath: file.path,
      destinationId: destination.id,
      destinationLabel: destination.label,
    );
    transfers.insert(0, record);
    _syncTransfers();
    try {
      final offer = await http.post(device.uri('/v1/offers'), headers: {..._authHeaders(device), 'content-type': 'application/json'}, body: jsonEncode({'id': id, 'sender': deviceName, 'fileName': fileName, 'size': length, 'destinationId': destination.id, 'relativePath': relativePath, 'sha256': hash.toString()})).timeout(const Duration(seconds: 90));
      if (offer.statusCode != 202) {
        _finishRecord(
          record,
          TransferState.rejected,
          message: offer.statusCode == 403 ? 'Receiver rejected the file' : 'Offer failed',
        );
        return;
      }
      record.state = TransferState.sending;
      _syncTransfers();
      final request = http.StreamedRequest('PUT', device.uri('/v1/transfers/$id'));
      request.headers.addAll(_authHeaders(device));
      request.contentLength = length;
      file.openRead().listen((chunk) { request.sink.add(chunk); record.done += chunk.length; onChanged(); }, onDone: request.sink.close, onError: request.sink.addError, cancelOnError: true);
      final result = await request.send().timeout(const Duration(hours: 4));
      final responseText = await result.stream.bytesToString();
      if (result.statusCode == 201) {
        record.done = length;
        final savedPath = responseText.trim();
        _finishRecord(
          record,
          TransferState.complete,
          message: savedPath.isNotEmpty ? savedPath : 'Delivered to ${destination.label}',
        );
      } else {
        _finishRecord(record, TransferState.failed, message: responseText);
      }
    } catch (e) {
      _finishRecord(record, TransferState.failed, message: e.toString());
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    request.response.headers.set('access-control-allow-origin', '*');
    try {
      if (request.method == 'POST' && request.uri.path == '/v1/pair') {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        if ('${body['pin']}' != pairingPin) { _text(request, 403, 'Incorrect PIN'); return; }
        final peerId = body['deviceId'];
        final peerSecret = body['secret'];
        if (peerId is String && peerSecret is String && peerId.isNotEmpty && peerSecret.isNotEmpty) {
          await _savePeer(peerId, peerSecret);
        }
        _json(request, 200, {'secret': deviceSecret, 'deviceId': deviceId});
        return;
      }
      if (request.uri.path.startsWith('/v1/') && request.headers.value('x-bretune-key') != deviceSecret) {
        _text(request, 401, 'Pairing required');
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/v1/destinations') {
        _json(request, 200, destinations.map((e) => e.toJson()).toList());
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/v1/offers') {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        final offer = PendingOffer.fromJson(body);
        final validDestination = destinations.any((d) => d.id == offer.destinationId);
        if (!validDestination || offer.fileName.contains('/') || offer.fileName.contains('\\')) {
          _text(request, 400, 'Invalid destination or filename');
          return;
        }
        final accepted = await onOffer(offer);
        if (!accepted) { _text(request, 403, 'Rejected'); return; }
        _accepted[offer.id] = offer;
        transfers.insert(0, TransferRecord(id: offer.id, fileName: offer.fileName, peer: offer.sender, total: offer.size, incoming: true, state: TransferState.waiting));
        _syncTransfers();
        _text(request, 202, 'Accepted');
        return;
      }
      if (request.method == 'PUT' && request.uri.pathSegments.length == 3 && request.uri.pathSegments[0] == 'v1' && request.uri.pathSegments[1] == 'transfers') {
        final id = request.uri.pathSegments[2];
        final offer = _accepted.remove(id);
        if (offer == null) { _text(request, 401, 'No accepted offer'); return; }
        final destination = destinations.firstWhere((d) => d.id == offer.destinationId);
        final relative = sanitizeRelativePath(offer.relativePath);
        final folder = relative.isEmpty ? Directory(destination.detail) : Directory(p.join(destination.detail, relative));
        await folder.create(recursive: true);
        var output = File(p.join(folder.path, offer.fileName));
        output = await _nonConflicting(output);
        final record = transfers.firstWhere((t) => t.id == id);
        record.state = TransferState.receiving;
        try {
          final sink = output.openWrite();
          await for (final chunk in request) {
            sink.add(chunk);
            record.done += chunk.length;
            onChanged();
          }
          await sink.close();
        } catch (e) {
          if (await output.exists()) await output.delete();
          _finishRecord(record, TransferState.failed, message: e.toString());
          _text(request, 500, e.toString());
          return;
        }
        final actual = (await sha256.bind(output.openRead()).first).toString();
        if (actual != offer.sha256 || record.done != offer.size) {
          await output.delete();
          _finishRecord(record, TransferState.failed, message: 'Integrity check failed');
          _text(request, 422, 'Integrity check failed');
        } else {
          _finishRecord(record, TransferState.complete, message: output.path);
          _text(request, 201, output.path);
        }
        return;
      }
      _text(request, 404, 'Not found');
    } catch (e) {
      _text(request, 500, e.toString());
    }
  }

  Future<File> _nonConflicting(File file) async {
    if (!await file.exists()) return file;
    final dir = p.dirname(file.path), ext = p.extension(file.path), base = p.basenameWithoutExtension(file.path);
    for (var i = 1; i < 10000; i++) {
      final candidate = File(p.join(dir, '$base ($i)$ext'));
      if (!await candidate.exists()) return candidate;
    }
    throw Exception('Too many duplicate files');
  }

  void _json(HttpRequest r, int status, Object body) { r.response.statusCode = status; r.response.headers.contentType = ContentType.json; r.response.write(jsonEncode(body)); r.response.close(); }
  void _text(HttpRequest r, int status, String body) { r.response.statusCode = status; r.response.write(body); r.response.close(); }

  Future<void> stop() async {
    await _discovery?.stop();
    await _broadcast?.stop();
    await _server?.close(force: true);
  }
}
