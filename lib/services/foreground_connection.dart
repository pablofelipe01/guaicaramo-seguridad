import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'meshtastic_service.dart';

/// Envuelve el `flutter_foreground_task` para mantener viva la conexión BLE
/// con el nodo cuando la pantalla se apaga.
///
/// Android suspende las apps en segundo plano (modo Doze) y mata el Bluetooth.
/// Un servicio en primer plano (con notificación persistente) impide esa
/// suspensión, así que el `keepAlive` y la conexión del nodo sobreviven.
///
/// El tipo de servicio es `connectedDevice`; por requisito de runtime de
/// Android 14+ el servicio solo se arranca cuando YA hay un nodo conectado.
class ForegroundConnection {
  ForegroundConnection._();

  static const _title = 'Guaicaramo Control';

  /// Configura el canal de notificación. Llamar una vez en `main()`.
  static void initOptions() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'guaicaramo_conexion',
        channelName: 'Conexión del nodo',
        channelDescription:
            'Mantiene la conexión Bluetooth con el nodo Meshtastic.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No corremos lógica en un isolate aparte: el BLE vive en el isolate
        // principal y el servicio solo evita que Android lo suspenda.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Pide el permiso de notificaciones (Android 13+). Sin él, no se puede
  /// mostrar la notificación del servicio en primer plano.
  static Future<void> requestPermissions() async {
    try {
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (e) {
      debugPrint('⚠️ [FGS] Error pidiendo permisos: $e');
    }
  }

  /// Texto de la notificación según el estado de conexión.
  static String _textFor(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.connected:
        return 'Nodo conectado ✓';
      case ConnectionStatus.connecting:
      case ConnectionStatus.scanning:
        return 'Conectando al nodo…';
      case ConnectionStatus.disconnected:
      case ConnectionStatus.error:
        return 'Sin conexión — reintentando…';
    }
  }

  /// Sincroniza el servicio/notificación con el estado actual.
  /// - Si el servicio corre → actualiza el texto.
  /// - Si no corre y ya hay nodo conectado → arranca el servicio.
  static Future<void> sync(ConnectionStatus status) async {
    final text = _textFor(status);
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: _title,
          notificationText: text,
        );
      } else if (status == ConnectionStatus.connected) {
        await FlutterForegroundTask.startService(
          serviceTypes: const [ForegroundServiceTypes.connectedDevice],
          notificationTitle: _title,
          notificationText: text,
        );
      }
    } catch (e) {
      debugPrint('⚠️ [FGS] Error sincronizando servicio: $e');
    }
  }

  /// Detiene el servicio en primer plano (al olvidar el dispositivo / salir).
  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      debugPrint('⚠️ [FGS] Error deteniendo servicio: $e');
    }
  }
}
