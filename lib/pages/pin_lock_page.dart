import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/color_constants.dart';

const _kPinKey = 'app_pin_hash';

/// Devuelve true si el usuario ya tiene PIN configurado.
Future<bool> hasPinSet() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.containsKey(_kPinKey);
}

String _hashPin(String pin) {
  final bytes = utf8.encode(pin);
  return sha256.convert(bytes).toString();
}

/// Guarda el PIN (hash).
Future<void> savePin(String pin) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kPinKey, _hashPin(pin));
}

/// Verifica si el PIN ingresado es correcto.
Future<bool> verifyPin(String pin) async {
  final prefs = await SharedPreferences.getInstance();
  final stored = prefs.getString(_kPinKey);
  if (stored == null) return true; // sin PIN configurado, pasa libre
  return stored == _hashPin(pin);
}

enum PinMode { setup, verify }

class PinLockPage extends StatefulWidget {
  final PinMode mode;
  /// Callback cuando el PIN es correcto / configurado.
  final VoidCallback onSuccess;

  const PinLockPage({
    Key? key,
    required this.mode,
    required this.onSuccess,
  }) : super(key: key);

  @override
  State<PinLockPage> createState() => _PinLockPageState();
}

class _PinLockPageState extends State<PinLockPage> {
  String _pin = '';
  String _confirmPin = '';
  bool _isConfirming = false;
  String _errorMsg = '';

  void _onKey(String digit) {
    if (_pin.length >= 6) return;
    setState(() {
      _errorMsg = '';
      _pin += digit;
    });
    if (_pin.length == 6) _handleComplete();
  }

  void _onDelete() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _handleComplete() async {
    if (widget.mode == PinMode.setup) {
      if (!_isConfirming) {
        // Primera vez: guardar y pedir confirmación
        setState(() {
          _confirmPin = _pin;
          _pin = '';
          _isConfirming = true;
        });
      } else {
        // Confirmación
        if (_pin == _confirmPin) {
          await savePin(_pin);
          widget.onSuccess();
        } else {
          setState(() {
            _pin = '';
            _confirmPin = '';
            _isConfirming = false;
            _errorMsg = 'Los PINs no coinciden. Intenta de nuevo.';
          });
        }
      }
    } else {
      // Modo verificación
      final ok = await verifyPin(_pin);
      if (ok) {
        widget.onSuccess();
      } else {
        setState(() {
          _pin = '';
          _errorMsg = 'PIN incorrecto';
        });
      }
    }
  }

  Widget _buildDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (i) {
        final filled = i < _pin.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 8),
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? ColorConstants.primaryColor : Colors.transparent,
            border: Border.all(
              color: ColorConstants.primaryColor,
              width: 2,
            ),
          ),
        );
      }),
    );
  }

  Widget _buildKey(String label, {VoidCallback? onTap, Widget? child}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(40),
      child: Container(
        width: 72,
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
        ),
        child: child ??
            Text(
              label,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                color: ColorConstants.textPrimary,
              ),
            ),
      ),
    );
  }

  Widget _buildKeypad() {
    final keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', 'del'],
    ];
    return Column(
      children: keys.map((row) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: row.map((k) {
              if (k == '') return const SizedBox(width: 72, height: 72);
              if (k == 'del') {
                return _buildKey(
                  '',
                  onTap: _onDelete,
                  child: const Icon(Icons.backspace_outlined,
                      color: ColorConstants.textPrimary),
                );
              }
              return _buildKey(k, onTap: () => _onKey(k));
            }).toList(),
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    String title;
    String subtitle;
    if (widget.mode == PinMode.setup) {
      title = _isConfirming ? 'Confirma tu PIN' : 'Crear PIN de acceso';
      subtitle = _isConfirming
          ? 'Ingresa el PIN nuevamente para confirmar'
          : 'Elige un PIN de 6 dígitos para proteger la app';
    } else {
      title = 'Ingresa tu PIN';
      subtitle = 'Ingresa tu PIN para continuar';
    }

    return Scaffold(
      backgroundColor: ColorConstants.bgApp,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60),
            const Icon(Icons.lock_outline_rounded,
                size: 56, color: ColorConstants.primaryColor),
            const SizedBox(height: 24),
            Text(title,
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: ColorConstants.textPrimary)),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 14, color: ColorConstants.textSecondary)),
            ),
            const SizedBox(height: 40),
            _buildDots(),
            const SizedBox(height: 16),
            AnimatedOpacity(
              opacity: _errorMsg.isEmpty ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              child: Text(_errorMsg,
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
            ),
            const Spacer(),
            _buildKeypad(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
