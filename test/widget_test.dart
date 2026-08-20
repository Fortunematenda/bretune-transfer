import 'package:bretune_transfer/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app models format sizes', () {
    expect(prettyBytes(2048), '2.0 KB');
  });
}
