import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Diálogo para pegar una clave/token que queda guardada solo en este
/// teléfono. Nunca muestra la clave completa: solo sus últimos 4 caracteres.
class ClaveDialog extends StatefulWidget {
  const ClaveDialog({
    super.key,
    required this.titulo,
    required this.descripcion,
    required this.hint,
    required this.sufijoActual,
    required this.guardar,
    required this.quitar,
    required this.advertenciaQuitar,
  });

  final String titulo;
  final String descripcion;
  final String hint;

  /// Últimos 4 caracteres de la clave guardada, o null si no hay.
  final String? Function() sufijoActual;

  /// Guarda y prueba la clave.
  final Future<({bool ok, String mensaje})> Function(String valor) guardar;
  final Future<void> Function() quitar;

  /// Qué deja de funcionar si se quita (se muestra antes de confirmar).
  final String advertenciaQuitar;

  @override
  State<ClaveDialog> createState() => _ClaveDialogState();
}

class _ClaveDialogState extends State<ClaveDialog> {
  final _ctrl = TextEditingController();
  bool _probando = false;
  ({bool ok, String mensaje})? _resultado;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _pegar() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final texto = data?.text?.trim();
    if (texto != null && texto.isNotEmpty) {
      setState(() => _ctrl.text = texto);
    }
  }

  Future<void> _guardar() async {
    setState(() {
      _probando = true;
      _resultado = null;
    });
    final r = await widget.guardar(_ctrl.text);
    if (!mounted) return;
    setState(() {
      _probando = false;
      _resultado = r;
      if (r.ok) _ctrl.clear();
    });
  }

  Future<void> _quitar() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Quitar la clave?'),
        content: Text(widget.advertenciaQuitar),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.quitar();
    if (mounted) setState(() => _resultado = null);
  }

  @override
  Widget build(BuildContext context) {
    final fin = widget.sufijoActual();
    return AlertDialog(
      title: Text(widget.titulo),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(fin != null ? Icons.check_circle : Icons.key_off,
                    color: fin != null ? Colors.green : Colors.red, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(fin != null
                      ? 'Clave guardada (termina en …$fin)'
                      : 'Sin clave configurada'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              widget.descripcion,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: fin != null ? 'Reemplazar clave' : 'Clave',
                hintText: widget.hint,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Pegar',
                  icon: const Icon(Icons.content_paste),
                  onPressed: _pegar,
                ),
              ),
            ),
            if (_probando) ...[
              const SizedBox(height: 12),
              const Row(
                children: [
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('Probando…'),
                ],
              ),
            ],
            if (_resultado != null) ...[
              const SizedBox(height: 12),
              Text(
                _resultado!.mensaje,
                style: TextStyle(
                  color: _resultado!.ok ? Colors.green.shade700 : Colors.orange.shade900,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (fin != null)
          TextButton(
            onPressed: _probando ? null : _quitar,
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Quitar'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
        FilledButton(
          onPressed: _probando || _ctrl.text.trim().isEmpty ? null : _guardar,
          child: const Text('Guardar y probar'),
        ),
      ],
    );
  }
}
