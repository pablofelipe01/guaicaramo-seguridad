import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../services/transcripcion_service.dart';
import 'clave_dialog.dart';

/// Abre la configuración de la clave de OpenAI (dictado por voz).
Future<void> mostrarClaveOpenAI(BuildContext context, [TranscripcionService? servicio]) {
  final tx = servicio ?? TranscripcionService.instance;
  return showDialog<void>(
    context: context,
    builder: (_) => ClaveDialog(
      titulo: 'Dictado por voz (OpenAI)',
      descripcion: 'Clave de API de OpenAI para transcribir las observaciones '
          'dictadas. Use una clave de proyecto con límite de gasto. Queda '
          'guardada solo en este teléfono. El dictado necesita internet.',
      hint: 'sk-…',
      sufijoActual: () => tx.claveFinal,
      guardar: tx.configurarClave,
      quitar: tx.quitarClave,
      advertenciaQuitar:
          'El micrófono dejará de transcribir hasta configurar otra clave.',
    ),
  );
}

/// Campo "Observación" con micrófono: el vigilante dicta y el texto aparece
/// en el campo (transcripción con OpenAI). El dictado necesita internet; sin
/// conexión la observación se escribe a mano, como siempre.
class CampoObservacion extends StatefulWidget {
  const CampoObservacion({
    super.key,
    required this.controller,
    required this.maxLength,
    this.onOcupado,
    this.transcripcion,
  });

  final TextEditingController controller;
  final int maxLength;

  /// Avisa cuando empieza/termina una grabación o transcripción, para que el
  /// formulario no se envíe a mitad de un dictado.
  final ValueChanged<bool>? onOcupado;
  final TranscripcionService? transcripcion;

  @override
  State<CampoObservacion> createState() => _CampoObservacionState();
}

enum _Mic { libre, preparando, grabando, transcribiendo }

class _CampoObservacionState extends State<CampoObservacion> {
  /// Tope de una grabación: se detiene sola y transcribe.
  static const int _maxSegundos = 90;

  _Mic _mic = _Mic.libre;
  AudioRecorder? _rec;
  String? _ruta;
  Timer? _reloj;
  int _segundos = 0;
  String? _aviso;
  bool _avisoEsError = false;

  TranscripcionService get _tx => widget.transcripcion ?? TranscripcionService.instance;

  void _setMic(_Mic m) {
    final antes = _mic != _Mic.libre;
    setState(() => _mic = m);
    final ahora = m != _Mic.libre;
    if (antes != ahora) widget.onOcupado?.call(ahora);
  }

  void _avisar(String? texto, {bool error = false}) {
    setState(() {
      _aviso = texto;
      _avisoEsError = error;
    });
  }

  Future<void> _empezar() async {
    _avisar(null);
    if (!_tx.configurado) {
      await mostrarClaveOpenAI(context, _tx);
      if (!mounted) return;
      if (_tx.configurado) _avisar('Listo. Toque el micrófono para dictar.');
      return;
    }

    _setMic(_Mic.preparando);
    if (!await TranscripcionService.hayInternet()) {
      if (!mounted) return;
      _setMic(_Mic.libre);
      _avisar('Sin internet: el dictado no está disponible. Escriba la observación.',
          error: true);
      return;
    }

    final rec = AudioRecorder();
    try {
      if (!await rec.hasPermission()) {
        await rec.dispose();
        if (!mounted) return;
        _setMic(_Mic.libre);
        _avisar('Sin permiso de micrófono. Actívelo en Ajustes › Apps › '
            'Guaicaramo Control › Permisos.', error: true);
        return;
      }
      final dir = await getTemporaryDirectory();
      final ruta =
          '${dir.path}/observacion_${DateTime.now().millisecondsSinceEpoch}.m4a';
      // Mono a 16 kHz: suficiente para voz y liviano para datos móviles
      // (~4 KB por segundo).
      await rec.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 32000,
          noiseSuppress: true,
        ),
        path: ruta,
      );
      if (!mounted) {
        await rec.cancel();
        await rec.dispose();
        return;
      }
      _rec = rec;
      _ruta = ruta;
      _segundos = 0;
      HapticFeedback.mediumImpact();
      _setMic(_Mic.grabando);
      _reloj = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _segundos++);
        if (_segundos >= _maxSegundos) _terminar();
      });
    } catch (e) {
      await rec.dispose();
      if (!mounted) return;
      _setMic(_Mic.libre);
      _avisar('No se pudo usar el micrófono: $e', error: true);
    }
  }

  Future<void> _terminar() async {
    _reloj?.cancel();
    final rec = _rec;
    if (rec == null) return;
    _rec = null;
    HapticFeedback.lightImpact();
    _setMic(_Mic.transcribiendo);
    String? ruta;
    try {
      ruta = await rec.stop();
    } catch (_) {
      // Si falla el stop se intenta con la ruta que se pidió al empezar.
    } finally {
      await rec.dispose();
    }
    ruta ??= _ruta;
    _ruta = null;
    if (ruta == null) {
      if (mounted) _setMic(_Mic.libre);
      return;
    }
    try {
      final texto = await _tx.transcribir(ruta);
      if (mounted) _insertar(texto);
    } on TranscripcionException catch (e) {
      if (mounted) _avisar(e.mensaje, error: true);
    } catch (e) {
      if (mounted) _avisar('No se pudo transcribir: $e', error: true);
    } finally {
      _borrar(ruta);
      if (mounted) _setMic(_Mic.libre);
    }
  }

  /// Agrega lo dictado al final de lo que ya hubiera escrito.
  void _insertar(String texto) {
    final actual = widget.controller.text.trim();
    var nuevo = actual.isEmpty ? texto : '$actual $texto';
    final recortado = nuevo.length > widget.maxLength;
    if (recortado) nuevo = nuevo.substring(0, widget.maxLength);
    widget.controller.value = TextEditingValue(
      text: nuevo,
      selection: TextSelection.collapsed(offset: nuevo.length),
    );
    _avisar(recortado
        ? 'Se recortó a ${widget.maxLength} caracteres; revise el texto.'
        : 'Revise el texto dictado antes de registrar.');
  }

  static void _borrar(String? ruta) {
    if (ruta == null) return;
    try {
      final f = File(ruta);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  @override
  void dispose() {
    _reloj?.cancel();
    final rec = _rec;
    if (rec != null) {
      // Se cerró el formulario a mitad de una grabación: se descarta el audio.
      final ruta = _ruta;
      rec.cancel().catchError((_) {}).whenComplete(() {
        rec.dispose();
        _borrar(ruta);
      });
    }
    super.dispose();
  }

  static String _mmss(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  Widget _boton() {
    switch (_mic) {
      case _Mic.grabando:
        return IconButton(
          tooltip: 'Terminar y transcribir',
          onPressed: _terminar,
          icon: Icon(Icons.stop_circle, color: Colors.red.shade700, size: 32),
        );
      case _Mic.preparando:
      case _Mic.transcribiendo:
        return const Padding(
          padding: EdgeInsets.all(14),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case _Mic.libre:
        return IconButton(
          tooltip: 'Dictar observación',
          onPressed: _empezar,
          icon: Icon(Icons.mic, color: Theme.of(context).colorScheme.primary),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? ayuda = switch (_mic) {
      _Mic.grabando => 'Escuchando… ${_mmss(_segundos)} · toque ■ para terminar',
      _Mic.transcribiendo => 'Transcribiendo…',
      _Mic.preparando => 'Preparando el micrófono…',
      _Mic.libre => _aviso,
    };
    final TextStyle? estiloAyuda = _mic == _Mic.grabando
        ? TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600)
        : _mic == _Mic.libre && _avisoEsError
            ? TextStyle(color: Colors.red.shade700)
            : null;

    return TextField(
      controller: widget.controller,
      maxLength: widget.maxLength,
      minLines: 1,
      maxLines: 4,
      readOnly: _mic != _Mic.libre,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: 'Observación (opcional)',
        border: const OutlineInputBorder(),
        helperText: ayuda,
        helperMaxLines: 3,
        helperStyle: estiloAyuda,
        suffixIcon: _boton(),
      ),
    );
  }
}
