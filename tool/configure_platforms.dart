import 'dart:io';

void main() {
  _patchAndroid();
  stdout.writeln('Platform permissions configured.');
}

void _patchAndroid() {
  final file = File('android/app/src/main/AndroidManifest.xml');
  if (!file.existsSync()) return;
  var text = file.readAsStringSync();
  const permissions = '''
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
    <uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.CAMERA" />''';
  if (!text.contains('CHANGE_WIFI_MULTICAST_STATE')) {
    text = text.replaceFirst('<manifest xmlns:android="http://schemas.android.com/apk/res/android">', '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n$permissions');
  }
  if (!text.contains('android:usesCleartextTraffic')) {
    text = text.replaceFirst('<application', '<application\n        android:usesCleartextTraffic="true"');
  }
  file.writeAsStringSync(text);
}
