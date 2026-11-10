import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Registro interno de la app en archivos de texto plano.
///
/// Todo lo que la app escribe con `debugPrint` (consultas, respuestas del
/// gateway, lista local, sincronizaciones, errores) queda además en
/// `registros/guaicaramo-AAAA-MM-DD.log`, un archivo por día y una línea por
/// evento con su hora. Los archivos de más de [diasRetencion] días se borran.
class RegistroLocal {
  RegistroLocal._();

  static const int diasRetencion = 30;
  static const Duration _cadaCuanto = Duration(seconds: 2);

  static Directory? _dir;
  static final StringBuffer _pendiente = StringBuffer();
  static String? _diaPendiente;
  static bool _escribiendo = false;
  static Timer? _temporizador;

  /// Carpeta donde quedan los archivos (null si no se pudo iniciar).
  static String? get carpeta => _dir?.path;

  /// Empieza a copiar los logs al archivo. En Android usa el almacenamiento
  /// de la app visible por USB (`Android/data/<app>/files/registros`).
  static Future<void> iniciar({Directory? carpeta}) async {
    if (_dir != null) return;
    try {
      final dir = carpeta ?? Directory('${(await _base()).path}/registros');
      await dir.create(recursive: true);
      _dir = dir;
    } catch (e) {
      debugPrint('❌ [REGISTRO] No se pudo abrir la carpeta de registros: $e');
      return;
    }
    _borrarViejos();

    final consola = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      consola(message, wrapWidth: wrapWidth);
      escribir(message ?? '');
    };
    final errorPrevio = FlutterError.onError;
    FlutterError.onError = (details) {
      escribir('❌ [FLUTTER] ${details.exceptionAsString()}\n${details.stack}');
      errorPrevio?.call(details);
    };
    _temporizador = Timer.periodic(_cadaCuanto, (_) => volcar());
    escribir('==== App iniciada ====');
  }

  /// Agrega una línea al registro (con la hora local).
  static void escribir(String linea) {
    if (_dir == null) return;
    final ahora = DateTime.now();
    final dia = _dia(ahora);
    // Un cambio de día a mitad de lote: lo anterior va primero a su archivo.
    if (_diaPendiente != null && _diaPendiente != dia) volcar();
    _diaPendiente ??= dia;
    _pendiente.writeln('${ahora.toIso8601String()} $linea');
  }

  /// Pasa a disco lo acumulado. Lo llama un temporizador cada 2 segundos.
  static Future<void> volcar() async {
    final dir = _dir;
    final dia = _diaPendiente;
    if (dir == null || dia == null || _escribiendo || _pendiente.isEmpty) return;
    final texto = _pendiente.toString();
    _pendiente.clear();
    _diaPendiente = null;
    _escribiendo = true;
    try {
      await File('${dir.path}/guaicaramo-$dia.log')
          .writeAsString(texto, mode: FileMode.append, flush: true);
    } catch (_) {
      // Sin espacio o sin permiso: no hay dónde avisar sin entrar en bucle.
    } finally {
      _escribiendo = false;
    }
  }

  static Future<Directory> _base() async {
    if (Platform.isAndroid) {
      final externo = await getExternalStorageDirectory();
      if (externo != null) return externo;
    }
    return getApplicationSupportDirectory();
  }

  static String _dia(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static void _borrarViejos() {
    try {
      final limite =
          DateTime.now().subtract(const Duration(days: diasRetencion));
      for (final f in _dir!.listSync().whereType<File>()) {
        if (f.path.endsWith('.log') && f.lastModifiedSync().isBefore(limite)) {
          f.deleteSync();
        }
      }
    } catch (_) {}
  }

  /// Solo para pruebas: vuelve al estado sin iniciar.
  @visibleForTesting
  static Future<void> cerrar() async {
    await volcar();
    _temporizador?.cancel();
    _dir = null;
  }
}
