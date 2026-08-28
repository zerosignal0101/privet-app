import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/device_name.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const platform = MethodChannel('privet/platform');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, null);
  });

  test('resolves the host name on desktop', () async {
    expect(await resolveDefaultDeviceName(isAndroid: false),
        Platform.localHostname);
  });

  test('uses the device model on Android', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, (call) async {
      if (call.method == 'getDeviceName') return 'TestManufacturer TestModel';
      return null;
    });
    expect(await resolveDefaultDeviceName(isAndroid: true),
        'TestManufacturer TestModel');
  });

  test('falls back to the host name when the Android channel is missing',
      () async {
    // No mock handler -> invokeMethod throws MissingPluginException.
    expect(await resolveDefaultDeviceName(isAndroid: true),
        Platform.localHostname);
  });

  test('falls back to privet-device when the host name is unavailable',
      () async {
    expect(
        await resolveDefaultDeviceName(
          isAndroid: false,
          hostname: () => throw StateError('no hostname'),
        ),
        'privet-device');
  });

  test('desktop config path points at the per-user privet dir', () {
    final path = desktopConfigPath();
    expect(path, isNotNull);
    expect(path, endsWith('privet${Platform.pathSeparator}config.json'));
  });

  test('writeDesktopDeviceNameConfig emits a partial daemon config', () async {
    final dir = Directory.systemTemp.createTempSync('privet-name');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final path =
        await writeDesktopDeviceNameConfig(path: '${dir.path}/config.json');
    expect(path, isNotNull);
    final json = File(path!).readAsStringSync();
    expect(json, contains('"device_name"'));
    expect(json, contains(Platform.localHostname));
  });

  test('writeDesktopDeviceNameConfig prefers the persisted pref', () async {
    final dir = Directory.systemTemp.createTempSync('privet-name');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    SharedPreferences.setMockInitialValues({'device_name': 'my-laptop'});
    final path =
        await writeDesktopDeviceNameConfig(path: '${dir.path}/config.json');
    final config = jsonDecode(File(path!).readAsStringSync());
    expect(config['device_name'], 'my-laptop');
  });

  test('writeDesktopDeviceNameConfig preserves persisted runtime fields',
      () async {
    final dir = Directory.systemTemp.createTempSync('privet-name');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final target = '${dir.path}/config.json';
    File(target).writeAsStringSync(jsonEncode({
      'device_name': 'old-host',
      'save_dir': r'D:\Downloads\privet',
      'accept_all_trusted': true,
    }));
    SharedPreferences.setMockInitialValues({'device_name': 'new-name'});
    final path = await writeDesktopDeviceNameConfig(path: target);
    final config = jsonDecode(File(path!).readAsStringSync());
    expect(config['device_name'], 'new-name');
    expect(config['save_dir'], r'D:\Downloads\privet');
    expect(config['accept_all_trusted'], isTrue);
  });
}
