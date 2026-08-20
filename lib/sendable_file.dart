import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Returns a readable file for upload, copying SAF/cache paths into app temp when needed.
Future<File> materializeSendableFile(PlatformFile picked) async {
  final path = picked.path;
  if (path != null && path.isNotEmpty) {
    final file = File(path);
    if (await file.exists()) {
      try {
        await file.openRead(0, 1).first;
        return file;
      } catch (_) {}
    }
  }

  final tempRoot = Directory(p.join((await getTemporaryDirectory()).path, 'bretune-send'));
  await tempRoot.create(recursive: true);
  final safeName = p.basename(picked.name.isNotEmpty ? picked.name : 'file');
  final tempFile = File(p.join(tempRoot.path, safeName));

  if (picked.readStream != null) {
    final sink = tempFile.openWrite();
    await picked.readStream!.pipe(sink);
    await sink.close();
    return tempFile;
  }

  if (picked.bytes != null) {
    await tempFile.writeAsBytes(picked.bytes!);
    return tempFile;
  }

  throw Exception('Cannot read ${picked.name}. Try picking the file again.');
}

Future<bool> canReadFile(File file) async {
  if (!await file.exists()) return false;
  try {
    await file.openRead(0, 1).first;
    return true;
  } catch (_) {
    return false;
  }
}

String sanitizeRelativePath(String raw) {
  var relative = p.normalize(raw).replaceAll('..', '');
  if (relative == '.' || relative == './') relative = '';
  return relative;
}
