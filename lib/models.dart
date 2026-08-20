import 'dart:io';

class NearbyDevice {
  NearbyDevice({required this.id, required this.name, required this.host, required this.port, required this.platform});
  final String id;
  final String name;
  final String host;
  final int port;
  final String platform;
  Uri uri(String path) => Uri(scheme: 'http', host: host, port: port, path: path);
}

class Destination {
  const Destination(this.id, this.label, this.detail);
  final String id;
  final String label;
  final String detail;
  factory Destination.fromJson(Map<String, dynamic> json) => Destination(json['id'], json['label'], json['detail'] ?? '');
  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'detail': detail};
}

enum TransferState { waiting, sending, receiving, complete, rejected, failed }

class TransferRecord {
  TransferRecord({
    required this.id,
    required this.fileName,
    required this.peer,
    required this.total,
    required this.incoming,
    required this.state,
    this.done = 0,
    this.message = '',
    this.peerDeviceId,
    this.filePath,
    this.destinationId,
    this.destinationLabel,
    DateTime? startedAt,
    this.finishedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  final String id;
  final String fileName;
  final String peer;
  final int total;
  final bool incoming;
  TransferState state;
  int done;
  String message;
  String? peerDeviceId;
  String? filePath;
  String? destinationId;
  String? destinationLabel;
  DateTime startedAt;
  DateTime? finishedAt;

  double get progress => total == 0 ? 0 : done / total;

  bool get isFinished => state == TransferState.complete || state == TransferState.failed || state == TransferState.rejected;

  bool get canResend =>
      !incoming &&
      (state == TransferState.failed || state == TransferState.rejected) &&
      filePath != null &&
      filePath!.isNotEmpty &&
      peerDeviceId != null &&
      destinationId != null;

  String get statusLabel => transferStatusLabel(state, incoming);

  DateTime get displayTime => finishedAt ?? startedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'fileName': fileName,
    'peer': peer,
    'peerDeviceId': peerDeviceId,
    'total': total,
    'incoming': incoming,
    'state': state.name,
    'done': done,
    'message': message,
    'filePath': filePath,
    'destinationId': destinationId,
    'destinationLabel': destinationLabel,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
  };

  factory TransferRecord.fromJson(Map<String, dynamic> json) => TransferRecord(
    id: json['id'] as String,
    fileName: json['fileName'] as String,
    peer: json['peer'] as String,
    total: json['total'] as int,
    incoming: json['incoming'] as bool,
    state: TransferState.values.byName(json['state'] as String),
    done: json['done'] as int? ?? 0,
    message: json['message'] as String? ?? '',
    peerDeviceId: json['peerDeviceId'] as String?,
    filePath: json['filePath'] as String?,
    destinationId: json['destinationId'] as String?,
    destinationLabel: json['destinationLabel'] as String?,
    startedAt: json['startedAt'] == null ? null : DateTime.tryParse(json['startedAt'] as String),
    finishedAt: json['finishedAt'] == null ? null : DateTime.tryParse(json['finishedAt'] as String),
  );
}

String transferStatusLabel(TransferState state, bool incoming) {
  return switch (state) {
    TransferState.waiting => incoming ? 'Waiting to receive' : 'Waiting to send',
    TransferState.sending => 'Sending',
    TransferState.receiving => 'Receiving',
    TransferState.complete => 'Delivered',
    TransferState.rejected => 'Rejected',
    TransferState.failed => 'Failed',
  };
}

String formatTransferTime(DateTime? time) {
  if (time == null) return '';
  final local = time.toLocal();
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final day = local.day.toString().padLeft(2, '0');
  final month = months[local.month - 1];
  final year = local.year;
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$day $month $year • $hh:$mm';
}

String friendlyStoragePath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final markers = <(String, String)>[
    ('/storage/emulated/0/Download/', 'Download/'),
    ('/storage/emulated/0/Downloads/', 'Download/'),
    ('/storage/emulated/0/Documents/', 'Documents/'),
    ('/storage/emulated/0/', 'Phone/'),
    ('/sdcard/Download/', 'Download/'),
    ('/sdcard/Documents/', 'Documents/'),
    ('/sdcard/', 'Phone/'),
  ];
  for (final marker in markers) {
    final index = normalized.indexOf(marker.$1);
    if (index >= 0) return '${marker.$2}${normalized.substring(index + marker.$1.length)}';
  }
  if (normalized.contains('/app_flutter/')) {
    final parts = normalized.split('/app_flutter/');
    return 'App storage/${parts.last}';
  }
  return path;
}

class PendingOffer {
  PendingOffer({required this.id, required this.sender, required this.fileName, required this.size, required this.destinationId, required this.relativePath, required this.sha256});
  final String id;
  final String sender;
  final String fileName;
  final int size;
  final String destinationId;
  final String relativePath;
  final String sha256;
  factory PendingOffer.fromJson(Map<String, dynamic> j) => PendingOffer(id: j['id'], sender: j['sender'], fileName: j['fileName'], size: j['size'], destinationId: j['destinationId'], relativePath: j['relativePath'] ?? '', sha256: j['sha256']);
}

String platformLabel() {
  if (Platform.isWindows) return 'Windows';
  if (Platform.isAndroid) return 'Android';
  return Platform.operatingSystem;
}

bool isGenericDeviceName(String? name) {
  if (name == null || name.trim().isEmpty) return true;
  final lower = name.trim().toLowerCase();
  return lower == 'localhost' ||
      lower == 'android' ||
      lower.startsWith('localhost.') ||
      lower == '127.0.0.1';
}

String displayDeviceName({String? preferred, String? fallbackPlatform, String? fallbackId}) {
  if (!isGenericDeviceName(preferred)) return preferred!.trim();
  if (fallbackPlatform != null && fallbackId != null && fallbackId.length >= 4) {
    return '$fallbackPlatform-${fallbackId.substring(0, 4)}';
  }
  if (fallbackPlatform != null) return fallbackPlatform;
  return 'Device';
}

String prettyBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
}
