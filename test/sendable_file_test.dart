import 'package:bretune_transfer/sendable_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('sanitizeRelativePath treats dot paths as root', () {
    expect(sanitizeRelativePath('.'), '');
    expect(sanitizeRelativePath('./'), '');
    expect(sanitizeRelativePath('photos'), 'photos');
    expect(sanitizeRelativePath('photos/nested'), p.join('photos', 'nested'));
  });
}
