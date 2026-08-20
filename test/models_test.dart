import 'package:bretune_transfer/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prettyBytes formats common sizes', () {
    expect(prettyBytes(500), '500 B');
    expect(prettyBytes(1024), '1.0 KB');
    expect(prettyBytes(1048576), '1.0 MB');
  });

  test('destination JSON round trip', () {
    const item = Destination('docs', 'Documents', '/docs');
    final decoded = Destination.fromJson(item.toJson());
    expect(decoded.id, 'docs');
    expect(decoded.label, 'Documents');
  });

  test('transfer status label uses Delivered for completed transfers', () {
    expect(transferStatusLabel(TransferState.complete, true), 'Delivered');
    expect(transferStatusLabel(TransferState.complete, false), 'Delivered');
  });

  test('formatTransferTime includes date and time', () {
    expect(formatTransferTime(DateTime(2026, 8, 20, 11, 4)), '20 Aug 2026 • 11:04');
  });

  test('friendlyStoragePath shortens Android public paths', () {
    expect(
      friendlyStoragePath('/storage/emulated/0/Download/Bretune Transfer/vs_BuildTools.exe'),
      'Download/Bretune Transfer/vs_BuildTools.exe',
    );
    expect(
      friendlyStoragePath('/data/user/0/com.bretunetech.bretune_transfer/app_flutter/Bretune Transfer/file.exe'),
      'App storage/Bretune Transfer/file.exe',
    );
  });

  test('transfer record JSON round trip', () {
    final record = TransferRecord(
      id: 'abc',
      fileName: 'photo.jpg',
      peer: 'Phone',
      peerDeviceId: 'device-1',
      total: 2048,
      incoming: false,
      state: TransferState.failed,
      filePath: r'C:\temp\photo.jpg',
      destinationId: 'downloads',
      destinationLabel: 'Downloads',
      finishedAt: DateTime(2026, 8, 20, 12, 30),
      message: 'Connection reset',
    );
    final decoded = TransferRecord.fromJson(record.toJson());
    expect(decoded.id, 'abc');
    expect(decoded.state, TransferState.failed);
    expect(decoded.canResend, isTrue);
    expect(transferStatusLabel(decoded.state, decoded.incoming), 'Failed');
  });
}
