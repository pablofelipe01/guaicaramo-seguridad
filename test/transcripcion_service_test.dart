import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:guaicaramo_control/services/transcripcion_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Campos del multipart enviado. Los archivos quedan como
/// `archivo:<nombre>:<bytes>:<4 primeros caracteres>`.
Map<String, String> _campos(http.Request req) {
  final boundary = req.headers['content-type']!.split('boundary=').last;
  final body = utf8.decode(req.bodyBytes, allowMalformed: true);
  final out = <String, String>{};
  for (final parte in body.split('--$boundary')) {
    final i = parte.indexOf('\r\n\r\n');
    if (i < 0) continue;
    final cabecera = parte.substring(0, i);
    final nombre = RegExp(r'name="([^"]+)"').firstMatch(cabecera)?.group(1);
    if (nombre == null) continue;
    final archivo = RegExp(r'filename="([^"]+)"').firstMatch(cabecera)?.group(1);
    var valor = parte.substring(i + 4);
    if (valor.endsWith('\r\n')) valor = valor.substring(0, valor.length - 2);
    out[nombre] = archivo == null
        ? valor
        : 'archivo:$archivo:${valor.length}:${valor.substring(0, 4)}';
  }
  return out;
}

http.Response _ok(String texto) => http.Response(
      jsonEncode({
        'text': texto,
        'languages': [
          {'code': 'es'}
        ],
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _err(int status, {String? code, String? param, String message = 'x'}) =>
    http.Response(
      jsonEncode({
        'error': {
          'message': message,
          'type': 'invalid_request_error',
          'code': code,
          'param': param,
        },
      }),
      status,
      headers: {'content-type': 'application/json'},
    );

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> peticiones;
  late http.Response Function(http.Request) responder;
  var sinRed = false;

  TranscripcionService nuevo() => TranscripcionService(
        httpClient: MockClient((req) async {
          if (sinRed) throw http.ClientException('Failed host lookup: api.openai.com');
          peticiones.add(req);
          return responder(req);
        }),
      );

  Future<String> audioDePrueba() async {
    final f = File('${Directory.systemTemp.path}/'
        'obs_test_${DateTime.now().microsecondsSinceEpoch}.m4a');
    await f.writeAsBytes(List.filled(64, 7));
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });
    return f.path;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    peticiones = [];
    sinRed = false;
    responder = (_) => _ok('');
  });

  test('clave válida: se prueba con medio segundo de silencio y queda guardada',
      () async {
    final s = nuevo();
    final r = await s.configurarClave('  sk-test-ABCD  ');
    expect(r.ok, isTrue, reason: r.mensaje);
    expect(s.configurado, isTrue);
    expect(s.claveFinal, 'ABCD');

    final req = peticiones.single;
    expect(req.url.toString(), 'https://api.openai.com/v1/audio/transcriptions');
    expect(req.headers['Authorization'], 'Bearer sk-test-ABCD');
    final c = _campos(req);
    expect(c['model'], 'gpt-transcribe');
    expect(c['languages[]'], 'es');
    expect(c.containsKey('language'), isFalse, reason: 'no se envían ambos');
    expect(c['prompt'], contains('Guaicaramo'));
    // WAV de 44 bytes de cabecera + 16000 de silencio (0,5 s a 16 kHz).
    expect(c['file'], 'archivo:prueba.wav:16044:RIFF');

    final s2 = nuevo();
    await _settle();
    expect(s2.configurado, isTrue, reason: 'persiste al reabrir la app');
  });

  test('clave inválida (401) no se guarda', () async {
    responder = (_) => _err(401, code: 'invalid_api_key');
    final s = nuevo();
    final r = await s.configurarClave('sk-mala-0000');
    expect(r.ok, isFalse);
    expect(r.mensaje, contains('no es válida'));
    expect(s.configurado, isFalse);

    final s2 = nuevo();
    await _settle();
    expect(s2.configurado, isFalse);
  });

  test('sin internet la clave se guarda para probarla después', () async {
    sinRed = true;
    final s = nuevo();
    final r = await s.configurarClave('sk-test-ABCD');
    expect(r.ok, isFalse);
    expect(r.mensaje, contains('no hay internet'));
    expect(s.configurado, isTrue);
  });

  test('transcribe el audio y limpia espacios', () async {
    SharedPreferences.setMockInitialValues({'openai_api_key': 'sk-test-ABCD'});
    responder = (_) => _ok('  Viene con un acompañante, placa KXY123.  ');
    final s = nuevo();
    final texto = await s.transcribir(await audioDePrueba());
    expect(texto, 'Viene con un acompañante, placa KXY123.');
    expect(_campos(peticiones.single)['file'], startsWith('archivo:observacion.m4a:64:'));
  });

  test('sin clave no intenta transcribir', () async {
    final s = nuevo();
    await expectLater(
      s.transcribir(await audioDePrueba()),
      throwsA(isA<TranscripcionException>()
          .having((e) => e.tipo, 'tipo', FalloTranscripcion.clave)),
    );
    expect(peticiones, isEmpty);
  });

  test('cuenta sin saldo (429 insufficient_quota) da un mensaje claro', () async {
    SharedPreferences.setMockInitialValues({'openai_api_key': 'sk-test-ABCD'});
    responder = (_) => _err(429, code: 'insufficient_quota');
    final s = nuevo();
    await expectLater(
      s.transcribir(await audioDePrueba()),
      throwsA(isA<TranscripcionException>()
          .having((e) => e.tipo, 'tipo', FalloTranscripcion.saldo)
          .having((e) => e.mensaje, 'mensaje', contains('saldo'))),
    );
  });

  test('sin red durante el envío pide escribir la observación', () async {
    SharedPreferences.setMockInitialValues({'openai_api_key': 'sk-test-ABCD'});
    final s = nuevo();
    final ruta = await audioDePrueba();
    sinRed = true;
    await expectLater(
      s.transcribir(ruta),
      throwsA(isA<TranscripcionException>()
          .having((e) => e.tipo, 'tipo', FalloTranscripcion.sinInternet)
          .having((e) => e.mensaje, 'mensaje', contains('Escriba'))),
    );
  });

  test('si la cuenta no tiene gpt-transcribe usa el modelo de respaldo', () async {
    SharedPreferences.setMockInitialValues({'openai_api_key': 'sk-test-ABCD'});
    responder = (req) => _campos(req)['model'] == 'gpt-transcribe'
        ? _err(404, code: 'model_not_found', param: 'model')
        : _ok('Todo en orden.');
    final s = nuevo();
    expect(await s.transcribir(await audioDePrueba()), 'Todo en orden.');
    expect(peticiones.length, 2);
    final respaldo = _campos(peticiones[1]);
    expect(respaldo['model'], 'gpt-4o-mini-transcribe');
    expect(respaldo['language'], 'es');
    expect(respaldo.containsKey('languages[]'), isFalse);

    // El respaldo se recuerda: la siguiente va directo.
    await s.transcribir(await audioDePrueba());
    expect(peticiones.length, 3);
    expect(_campos(peticiones[2])['model'], 'gpt-4o-mini-transcribe');
  });

  test('audio sin palabras pide repetir', () async {
    SharedPreferences.setMockInitialValues({'openai_api_key': 'sk-test-ABCD'});
    responder = (_) => _ok('   ');
    final s = nuevo();
    await expectLater(
      s.transcribir(await audioDePrueba()),
      throwsA(isA<TranscripcionException>()
          .having((e) => e.tipo, 'tipo', FalloTranscripcion.vacio)),
    );
  });

  test('quitar la clave desactiva el dictado', () async {
    SharedPreferences.setMockInitialValues({'openai_api_key': 'sk-test-ABCD'});
    final s = nuevo();
    await _settle();
    expect(s.configurado, isTrue);
    await s.quitarClave();
    expect(s.configurado, isFalse);
    final s2 = nuevo();
    await _settle();
    expect(s2.configurado, isFalse);
  });
}
