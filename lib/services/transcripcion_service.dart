import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, HandshakeException, InternetAddress, SocketException;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String _claveKey = 'openai_api_key';

/// Por qué no se pudo transcribir. Decide qué se le dice al vigilante.
enum FalloTranscripcion {
  /// Sin red, DNS o timeout.
  sinInternet,

  /// 401: clave inválida o revocada.
  clave,

  /// 403: la clave no puede usar audio (clave restringida, región, etc.).
  permiso,

  /// 429 por falta de saldo en la cuenta.
  saldo,

  /// 429 por exceso de peticiones: reintentar en unos segundos.
  ocupado,

  /// 4xx sobre el archivo (formato, duración…).
  audio,

  /// OpenAI respondió pero no reconoció palabras.
  vacio,

  /// 5xx u otra respuesta inesperada.
  servidor,
}

class TranscripcionException implements Exception {
  final FalloTranscripcion tipo;
  final String mensaje;

  const TranscripcionException(this.tipo, this.mensaje);

  @override
  String toString() => 'TranscripcionException($tipo): $mensaje';
}

/// Voz a texto para las observaciones del módulo de gerentes (API de OpenAI).
///
/// Requiere internet: sin conexión el vigilante escribe la observación a mano y
/// el resto del módulo sigue funcionando igual. La clave de OpenAI se pide en la
/// app y queda guardada solo en este teléfono (nunca dentro del APK).
class TranscripcionService extends ChangeNotifier {
  TranscripcionService({http.Client? httpClient})
      : _http = httpClient ?? http.Client() {
    _cargado = _load();
  }

  static final TranscripcionService instance = TranscripcionService();

  /// Modelo que OpenAI recomienda para transcribir archivos grabados.
  static const String modelo = 'gpt-transcribe';

  /// Respaldo si la cuenta no tiene acceso a [modelo].
  static const String modeloRespaldo = 'gpt-4o-mini-transcribe';

  /// Orienta el vocabulario. A propósito sin datos personales: solo el contexto.
  static const String prompt =
      'Observación de un vigilante de portería en la plantación Guaicaramo '
      '(Colombia) sobre el ingreso o la salida de un gerente de una unidad '
      'externa. Puede mencionar placas de vehículos como KXY123.';

  static const Duration _timeout = Duration(seconds: 60);

  final http.Client _http;
  late final Future<void> _cargado;
  String? _clave;

  /// La cuenta no tuvo acceso a [modelo]: se usa [modeloRespaldo] el resto de
  /// la sesión.
  bool _usarRespaldo = false;

  bool get configurado => _clave != null && _clave!.isNotEmpty;

  /// Últimos 4 caracteres de la clave guardada (nunca se muestra completa).
  String? get claveFinal => configurado ? _clave!.substring(_clave!.length - 4) : null;

  // ---------- Configuración ----------

  /// Guarda la clave y la prueba con medio segundo de silencio: así se valida
  /// con el mismo endpoint y permisos que usa el dictado (sirve aunque la
  /// clave esté restringida solo a audio).
  Future<({bool ok, String mensaje})> configurarClave(String clave) async {
    await _cargado;
    clave = clave.trim();
    if (clave.isEmpty) return (ok: false, mensaje: 'Pegue la clave de OpenAI.');
    final anterior = _clave;
    _clave = clave;
    _usarRespaldo = false;
    try {
      await _enviar(_silencioWav(), 'prueba.wav');
    } on TranscripcionException catch (e) {
      switch (e.tipo) {
        case FalloTranscripcion.clave:
        case FalloTranscripcion.permiso:
          // Una clave que no sirve no se guarda (se conserva la anterior).
          _clave = anterior;
          notifyListeners();
          return (ok: false, mensaje: e.mensaje);
        case FalloTranscripcion.sinInternet:
          await _guardar(clave);
          return (
            ok: false,
            mensaje: 'Clave guardada, pero no hay internet para probarla. '
                'Se probará al usar el micrófono.',
          );
        case FalloTranscripcion.audio:
        case FalloTranscripcion.vacio:
          // OpenAI aceptó la clave; solo le pareció raro el audio de prueba.
          break;
        case FalloTranscripcion.saldo:
        case FalloTranscripcion.ocupado:
        case FalloTranscripcion.servidor:
          await _guardar(clave);
          return (ok: false, mensaje: 'Clave guardada. Aviso de OpenAI: ${e.mensaje}');
      }
    }
    await _guardar(clave);
    return (ok: true, mensaje: 'Clave correcta: el micrófono ya transcribe.');
  }

  Future<void> quitarClave() async {
    await _cargado;
    _clave = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_claveKey);
    } catch (_) {}
    notifyListeners();
  }

  // ---------- Transcripción ----------

  /// Comprobación rápida antes de grabar, para no hacer hablar al vigilante en
  /// vano cuando no hay conexión.
  static Future<bool> hayInternet() async {
    try {
      final r = await InternetAddress.lookup('api.openai.com')
          .timeout(const Duration(seconds: 5));
      return r.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Transcribe el audio grabado en [rutaAudio]. Lanza
  /// [TranscripcionException] con un mensaje listo para mostrar.
  Future<String> transcribir(String rutaAudio) async {
    await _cargado;
    if (!configurado) {
      throw const TranscripcionException(
          FalloTranscripcion.clave, 'Falta configurar la clave de OpenAI.');
    }
    final audio = await File(rutaAudio).readAsBytes();
    final texto = (await _enviar(audio, 'observacion.m4a')).trim();
    if (texto.isEmpty) {
      throw const TranscripcionException(FalloTranscripcion.vacio,
          'No se entendió el audio. Hable más cerca del teléfono e intente de nuevo.');
    }
    return texto;
  }

  Future<String> _enviar(List<int> audio, String nombre) async {
    if (!_usarRespaldo) {
      try {
        return await _peticion(audio, nombre, respaldo: false);
      } on _ModeloNoDisponible {
        debugPrint('🎙️ [VOZ] $modelo no disponible; uso $modeloRespaldo');
        _usarRespaldo = true;
      }
    }
    return _peticion(audio, nombre, respaldo: true);
  }

  Future<String> _peticion(List<int> audio, String nombre, {required bool respaldo}) async {
    final req = http.MultipartRequest(
        'POST', Uri.https('api.openai.com', '/v1/audio/transcriptions'))
      ..headers['Authorization'] = 'Bearer $_clave'
      ..fields['model'] = respaldo ? modeloRespaldo : modelo
      ..fields['prompt'] = prompt
      // gpt-transcribe recibe una lista de idiomas; los modelos anteriores, uno solo.
      ..fields[respaldo ? 'language' : 'languages[]'] = 'es'
      ..files.add(http.MultipartFile.fromBytes('file', audio, filename: nombre));

    final http.Response resp;
    try {
      final streamed = await _http.send(req).timeout(_timeout);
      resp = await http.Response.fromStream(streamed).timeout(_timeout);
    } on TimeoutException {
      throw const TranscripcionException(FalloTranscripcion.sinInternet,
          'OpenAI no respondió a tiempo. Escriba la observación o intente de nuevo.');
    } on SocketException {
      throw _sinConexion;
    } on HandshakeException {
      throw _sinConexion;
    } on http.ClientException {
      throw _sinConexion;
    }

    if (resp.statusCode == 200) {
      final body = jsonDecode(utf8.decode(resp.bodyBytes));
      final texto = body is Map<String, dynamic> ? body['text'] : null;
      return texto is String ? texto : '';
    }

    final (code, param, detalle) = _error(resp);
    final status = resp.statusCode;
    if (!respaldo && (status == 404 || code == 'model_not_found' || param == 'model')) {
      throw const _ModeloNoDisponible();
    }
    if (status == 401) {
      throw const TranscripcionException(
          FalloTranscripcion.clave, 'La clave de OpenAI no es válida.');
    }
    if (status == 403) {
      throw TranscripcionException(FalloTranscripcion.permiso,
          'La clave de OpenAI no tiene permiso para transcribir audio ($detalle).');
    }
    if (status == 429) {
      throw code == 'insufficient_quota'
          ? const TranscripcionException(
              FalloTranscripcion.saldo, 'La cuenta de OpenAI no tiene saldo disponible.')
          : const TranscripcionException(
              FalloTranscripcion.ocupado, 'OpenAI está ocupado; intente en unos segundos.');
    }
    if (status >= 500) {
      throw TranscripcionException(
          FalloTranscripcion.servidor, 'OpenAI falló (HTTP $status); intente de nuevo.');
    }
    if (status >= 400 && status < 500) {
      throw TranscripcionException(
          FalloTranscripcion.audio, 'OpenAI no pudo procesar el audio: $detalle');
    }
    throw TranscripcionException(
        FalloTranscripcion.servidor, 'Respuesta inesperada de OpenAI (HTTP $status).');
  }

  static const _sinConexion = TranscripcionException(FalloTranscripcion.sinInternet,
      'Sin conexión: no se pudo transcribir. Escriba la observación.');

  /// `error.code`, `error.param` y `error.message` del cuerpo de error de OpenAI.
  static (String?, String?, String) _error(http.Response resp) {
    try {
      final err = (jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>)['error'];
      if (err is Map<String, dynamic>) {
        return (
          err['code'] as String?,
          err['param'] as String?,
          (err['message'] ?? 'HTTP ${resp.statusCode}').toString(),
        );
      }
    } catch (_) {}
    return (null, null, 'HTTP ${resp.statusCode}');
  }

  /// WAV PCM 16 bits mono de medio segundo de silencio (para validar la clave).
  static Uint8List _silencioWav() {
    const sampleRate = 16000;
    const datos = sampleRate ~/ 2 * 2; // 0,5 s × 2 bytes por muestra
    final b = ByteData(44 + datos);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    b.setUint32(4, 36 + datos, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    b.setUint32(16, 16, Endian.little); // tamaño del bloque fmt
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little); // bytes por segundo
    b.setUint16(32, 2, Endian.little); // bytes por muestra
    b.setUint16(34, 16, Endian.little); // bits por muestra
    ascii(36, 'data');
    b.setUint32(40, datos, Endian.little);
    return b.buffer.asUint8List();
  }

  // ---------- Persistencia ----------

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _clave = prefs.getString(_claveKey);
      notifyListeners();
    } catch (e) {
      debugPrint('❌ [VOZ] Error cargando clave: $e');
    }
  }

  Future<void> _guardar(String clave) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_claveKey, clave);
    } catch (e) {
      debugPrint('❌ [VOZ] Error guardando clave: $e');
    }
    notifyListeners();
  }
}

/// El modelo principal no está disponible para esta cuenta (→ respaldo).
class _ModeloNoDisponible implements Exception {
  const _ModeloNoDisponible();
}
