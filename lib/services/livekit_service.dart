import 'dart:convert';

import 'package:flutter_chat_demo/constants/app_constants.dart';
import 'package:http/http.dart' as http;

class LiveKitTokenData {
  final String token;
  final String url;

  const LiveKitTokenData({required this.token, required this.url});
}

class LiveKitService {
  static Future<LiveKitTokenData> createRoomToken({
    required String identity,
    required String roomName,
    String? name,
  }) async {
    final resp = await http
        .post(
          Uri.parse(AppConstants.liveKitTokenApiUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'identity': identity,
            'room': roomName,
            if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
          }),
        )
        .timeout(const Duration(seconds: 12));

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final ok = data['success'] == true;
    final token = (data['token'] as String? ?? '').trim();
    final url = (data['url'] as String? ?? '').trim();

    if (!ok || token.isEmpty || url.isEmpty) {
      throw Exception(data['error'] ?? 'No se pudo generar token LiveKit');
    }

    return LiveKitTokenData(token: token, url: url);
  }
}
