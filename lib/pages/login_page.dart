import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/pages/pages.dart';
import 'package:flutter_chat_demo/providers/auth_provider.dart';
import 'package:flutter_chat_demo/utils/app_updater.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

class LoginPage extends StatefulWidget {
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with WidgetsBindingObserver {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  String _appVersion = '';

  late final YoutubePlayerController _ytController;
  static const _videoId = 'SC_HySSCUe4';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = info.version);
    });
    _ytController = YoutubePlayerController.fromVideoId(
      videoId: _videoId,
      autoPlay: true,
      params: const YoutubePlayerParams(
        mute: false,
        showControls: false,
        showFullscreenButton: false,
        loop: true,
        showVideoAnnotations: false,
        strictRelatedVideos: true,
        enableCaption: false,
        playsInline: true,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _usernameController.dispose();
    _passwordController.dispose();
    _ytController.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    switch (authProvider.status) {
      case Status.authenticateError:
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final msg = authProvider.lastErrorMessage.isNotEmpty
              ? authProvider.lastErrorMessage
              : 'Usuario o contraseña incorrectos';
          Fluttertoast.showToast(msg: msg, backgroundColor: Colors.red);
        });
        break;
      case Status.authenticated:
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Fluttertoast.showToast(
            msg: '¡Bienvenido, aventurero!',
            backgroundColor: const Color(0xFFFFD700),
            textColor: Colors.black,
          );
        });
        break;
      default:
        break;
    }

    return YoutubePlayerScaffold(
      controller: _ytController,
      builder: (context, player) {
        return Scaffold(
          resizeToAvoidBottomInset: true,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // ── YouTube video fullscreen background ──
              SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: 16,
                    height: 9,
                    child: player,
                  ),
                ),
              ),
              // ── Dark overlay ──
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xCC000020),
                      Color(0xDD000015),
                      Color(0xEE000010),
                    ],
                  ),
                ),
              ),
              // ── Content ──
              SafeArea(
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: MediaQuery.of(context).size.height -
                          MediaQuery.of(context).padding.top,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        children: [
                          const SizedBox(height: 32),
                          _buildLogo(),
                          const SizedBox(height: 16),
                          _buildPromoText(),
                          const Spacer(),
                          _buildLoginCard(authProvider),
                          const SizedBox(height: 12),
                          _buildRegisterButton(),
                          const SizedBox(height: 20),
                          Text(
                            _appVersion.isNotEmpty
                                ? 'v$_appVersion  ·  By Mr. Unknown'
                                : 'By Mr. Unknown',
                            style: const TextStyle(color: Colors.white38, fontSize: 11),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLogo() {
    return Column(
      children: [
        Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF000033),
            border: Border.all(color: const Color(0xFFFFD700), width: 2.5),
            boxShadow: [
              BoxShadow(
                  color: const Color(0xFFFFD700).withOpacity(0.5),
                  blurRadius: 24,
                  spreadRadius: 2),
              BoxShadow(
                  color: const Color(0xFF4466FF).withOpacity(0.4),
                  blurRadius: 32,
                  spreadRadius: 4),
            ],
          ),
          child: const Icon(Icons.shield, size: 50, color: Color(0xFFFFD700)),
        ),
        const SizedBox(height: 14),
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFFFFD700), Color(0xFFFFF0A0), Color(0xFFFFD700)],
          ).createShader(bounds),
          child: const Text(
            'MuOnline',
            style: TextStyle(
              color: Colors.white,
              fontSize: 40,
              fontWeight: FontWeight.w900,
              letterSpacing: 4,
              shadows: [
                Shadow(color: Color(0xFFFFD700), blurRadius: 16),
                Shadow(color: Color(0xFF0044FF), blurRadius: 32),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Season 19  •  Continent of Legend',
          style: TextStyle(
            color: Color(0xFF8899CC),
            fontSize: 11,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _buildPromoText() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.5)),
        borderRadius: BorderRadius.circular(8),
        color: Colors.black45,
      ),
      child: const Text(
        '⚔️  Regístrate en este juego y gana\nun Full Set +15 al iniciar sesión  ⚔️',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Color(0xFFFFD700),
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1.5,
          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
        ),
      ),
    );
  }

  Widget _buildLoginCard(AuthProvider authProvider) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF000033).withOpacity(0.75),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: const Color(0xFFFFD700).withOpacity(0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'INICIAR SESIÓN',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFFD700),
                    letterSpacing: 2,
                    shadows: [
                      Shadow(color: Color(0xFFFFD700), blurRadius: 8)
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _muTextField(
                  controller: _usernameController,
                  hint: 'Usuario',
                  icon: Icons.person_outline,
                  action: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                _muTextField(
                  controller: _passwordController,
                  hint: 'Contraseña',
                  icon: Icons.lock_outline,
                  obscure: _obscurePassword,
                  action: TextInputAction.done,
                  onSubmitted: (_) => _signIn(authProvider),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: const Color(0xFF8899CC),
                      size: 20,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 50,
                  child: ElevatedButton(
                    onPressed: authProvider.status == Status.authenticating
                        ? null
                        : () => _signIn(authProvider),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFD700),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      elevation: 6,
                      shadowColor:
                          const Color(0xFFFFD700).withOpacity(0.6),
                    ),
                    child: authProvider.status == Status.authenticating
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                color: Colors.black, strokeWidth: 2.5),
                          )
                        : const Text(
                            '⚔️  ENTRAR AL JUEGO',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.2,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _muTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    TextInputAction action = TextInputAction.next,
    ValueChanged<String>? onSubmitted,
    Widget? suffixIcon,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      textInputAction: action,
      onSubmitted: onSubmitted,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF6677AA)),
        prefixIcon: Icon(icon, color: const Color(0xFF8899CC), size: 20),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: const Color(0xFF000044).withOpacity(0.7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
              color: const Color(0xFFFFD700).withOpacity(0.3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
              color: const Color(0xFFFFD700).withOpacity(0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFFFD700)),
        ),
        contentPadding:
            const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
      ),
    );
  }

  Widget _buildRegisterButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: OutlinedButton.icon(
        onPressed: () async {
          final uri =
              Uri.parse('https://www.mu-online.cl/regnewuser.asp');
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
        icon: const Icon(Icons.app_registration,
            size: 18, color: Color(0xFF8899CC)),
        label: const Text(
          'Crear cuenta nueva',
          style: TextStyle(color: Color(0xFF8899CC), letterSpacing: 0.5),
        ),
        style: OutlinedButton.styleFrom(
          side: BorderSide(
              color: const Color(0xFF8899CC).withOpacity(0.4)),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          minimumSize: const Size(double.infinity, 0),
        ),
      ),
    );
  }

  Future<void> _signIn(AuthProvider authProvider) async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      Fluttertoast.showToast(msg: 'Usuario y contraseña son obligatorios');
      return;
    }

    final isSuccess =
        await authProvider.handlePageSignIn(username, password);
    if (!mounted) return;
    if (isSuccess) {
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => HomePage()),
      );
    } else {
      final message = authProvider.lastErrorMessage.isNotEmpty
          ? authProvider.lastErrorMessage
          : 'No se pudo iniciar sesión';
      Fluttertoast.showToast(msg: message, backgroundColor: Colors.red);
    }
  }
}
