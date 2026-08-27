import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/device_name.dart';
import '../services/ipc/dto.dart';
import '../state/daemon_state.dart';

/// App-local settings merged with the daemon's live runtime config. Daemon
/// values (`saveDir`, `acceptAllTrusted`, `collisionPolicy`) are refreshed via
/// [SettingsNotifier.loadFromDaemon]; app prefs (`deviceName`,
/// `leaveDaemonRunning`) persist in SharedPreferences.
class Settings {
  const Settings({
    this.deviceName = 'privet-device',
    this.saveDir,
    this.acceptAllTrusted = false,
    this.collisionPolicy = 'rename',
    this.leaveDaemonRunning = false,
  });

  final String deviceName;
  final String? saveDir;
  final bool acceptAllTrusted;
  final String collisionPolicy;
  final bool leaveDaemonRunning;

  Settings copyWith({
    String? deviceName,
    String? saveDir,
    bool? acceptAllTrusted,
    String? collisionPolicy,
    bool? leaveDaemonRunning,
    bool clearSaveDir = false,
  }) =>
      Settings(
        deviceName: deviceName ?? this.deviceName,
        saveDir: clearSaveDir ? null : (saveDir ?? this.saveDir),
        acceptAllTrusted: acceptAllTrusted ?? this.acceptAllTrusted,
        collisionPolicy: collisionPolicy ?? this.collisionPolicy,
        leaveDaemonRunning: leaveDaemonRunning ?? this.leaveDaemonRunning,
      );
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<Settings> {
  @override
  Settings build() {
    _loadPrefs();
    final service = ref.watch(daemonStateProvider).service;
    if (service != null) {
      // Merge the daemon's live runtime config once it is up.
      service.runtimeConfig().then(loadFromDaemon).catchError((_) {});
    }
    return const Settings();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    state = state.copyWith(
      // Default device name: host name on desktop, device model on Android.
      deviceName:
          prefs.getString('device_name') ?? await resolveDefaultDeviceName(),
      leaveDaemonRunning:
          prefs.getBool('leave_daemon_running') ?? state.leaveDaemonRunning,
    );
  }

  /// Merge the daemon's current runtime config into the settings view.
  Future<void> loadFromDaemon(RuntimeConfigDto config) async {
    state = state.copyWith(
      saveDir: config.saveDir,
      acceptAllTrusted: config.acceptAllTrusted,
      collisionPolicy: config.collisionPolicy,
    );
  }

  Future<void> setDeviceName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_name', name);
    state = state.copyWith(deviceName: name);
  }

  Future<void> setSaveDir(String dir) async {
    await ref.read(daemonStateProvider).service?.setRuntimeConfig(saveDir: dir);
    state = state.copyWith(saveDir: dir);
  }

  Future<void> setAcceptAllTrusted(bool value) async {
    await ref
        .read(daemonStateProvider)
        .service
        ?.setRuntimeConfig(acceptAllTrusted: value);
    state = state.copyWith(acceptAllTrusted: value);
  }

  Future<void> setCollisionPolicy(String value) async {
    await ref
        .read(daemonStateProvider)
        .service
        ?.setRuntimeConfig(collisionPolicy: value);
    state = state.copyWith(collisionPolicy: value);
  }

  Future<void> setLeaveDaemonRunning(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('leave_daemon_running', value);
    state = state.copyWith(leaveDaemonRunning: value);
  }
}
