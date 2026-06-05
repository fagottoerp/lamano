import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/app_constants.dart';
import 'package:flutter_chat_demo/constants/color_constants.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:http/http.dart' as http;
import 'package:photo_view/photo_view.dart';

class FullPhotoPage extends StatelessWidget {
  final String url;

  const FullPhotoPage({super.key, required this.url});

  Future<void> _downloadImage(BuildContext context) async {
    try {
      Fluttertoast.showToast(msg: 'Descargando...');
      final response = await http.get(Uri.parse(url));
      final fileName = 'lamano_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final dir = Directory('/storage/emulated/0/Download');
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(response.bodyBytes);
      Fluttertoast.showToast(msg: 'Guardado en Downloads');
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error al descargar');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          AppConstants.fullPhotoTitle,
          style: TextStyle(color: ColorConstants.primaryColor),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Descargar imagen',
            onPressed: () => _downloadImage(context),
          ),
        ],
      ),
      body: Container(
        child: PhotoView(
          imageProvider: NetworkImage(url),
        ),
      ),
    );
  }
}
