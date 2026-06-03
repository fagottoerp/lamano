import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_demo/constants/constants.dart';
import 'package:flutter_chat_demo/pages/full_photo_page.dart';
import 'package:flutter_chat_demo/pages/full_video_page.dart';
import 'package:flutter_chat_demo/providers/providers.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

const String _kCaminadorRoleId = '3732';
const String _kRoutesCollection = 'caminador_routes';
const String _kRouteEventsCollection = 'events';
const String _kRoutePositionsCollection = 'positions';
const String _kActiveRoutePrefKey = 'caminador_active_route_id';
const int _kPersistentAlertTtlMs = 315360000000; // 10 years

class CaminadorPage extends StatefulWidget {
  const CaminadorPage({super.key, required this.isAdmin, required this.isCaminador});

  final bool isAdmin;
  final bool isCaminador;

  @override
  State<CaminadorPage> createState() => _CaminadorPageState();
}

class _CaminadorPageState extends State<CaminadorPage> {
  final ImagePicker _picker = ImagePicker();
  final DateFormat _dateFormat = DateFormat('dd/MM · HH:mm');

  late final AuthProvider _authProvider = context.read<AuthProvider>();
  StreamSubscription<Position>? _trackingSub;

  String? _activeTrackingRouteId;
  String? _expandedRouteId;
  bool _busyTracking = false;
  bool _uploadingEvidence = false;

  String get _currentUserId => _authProvider.userFirebaseId ?? '';
  String get _currentNickname =>
      _authProvider.prefs.getString(FirestoreConstants.nickname) ?? 'Usuario';
  bool get _canOperateRoutes => widget.isCaminador || widget.isAdmin;

  @override
  void initState() {
    super.initState();
    _activeTrackingRouteId =
        _authProvider.prefs.getString(_kActiveRoutePrefKey)?.trim();
  }

  @override
  void dispose() {
    _trackingSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: ColorConstants.bgApp,
      child: SafeArea(
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection(_kRoutesCollection).snapshots(),
          builder: (context, snapshot) {
            final routes = _visibleRoutes(snapshot.data?.docs ?? const []);
            final activeCount = routes.where((r) => _statusOf(r.data) == 'active').length;
            final plannedCount = routes.where((r) => _statusOf(r.data) == 'planned').length;
            final doneCount = routes.where((r) => _statusOf(r.data) == 'completed').length;

            return RefreshIndicator(
              onRefresh: () async => setState(() {}),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                children: [
                  _buildHeroCard(activeCount, plannedCount, doneCount),
                  const SizedBox(height: 14),
                  if (widget.isAdmin) _buildAdminActions(),
                  if (widget.isAdmin) const SizedBox(height: 14),
                  _buildLegendCard(),
                  const SizedBox(height: 16),
                  if (routes.isEmpty)
                    _buildEmptyState()
                  else
                    ...routes.map(_buildRouteCard),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  List<_RouteDoc> _visibleRoutes(List<QueryDocumentSnapshot> docs) {
    final mapped = docs.map((doc) {
      final data = Map<String, dynamic>.from(doc.data() as Map<String, dynamic>);
      return _RouteDoc(id: doc.id, data: data);
    }).where((route) {
      if (widget.isAdmin) return true;
      return route.data['assignedToUserId'] == _currentUserId ||
          route.data['createdByUserId'] == _currentUserId;
    }).toList();

    mapped.sort((a, b) => (_createdAtMsOf(b.data)).compareTo(_createdAtMsOf(a.data)));
    return mapped;
  }

  Widget _buildHeroCard(int activeCount, int plannedCount, int doneCount) {
    final title = widget.isAdmin ? 'Centro Caminador' : 'Ruta Caminador';
    final subtitle = widget.isAdmin
        ? 'Crea misiones, marca trayectos y vigila evidencias en tiempo real.'
        : 'Sigue la ruta estilo Waze, deja trazado GPS y sube pruebas en cada punto.';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0F766E), Color(0xFF115E59), Color(0xFF083344)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF083344).withValues(alpha: 0.24),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.route_rounded, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.82),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _buildSummaryChip(Icons.play_circle_fill_rounded, '$activeCount activas'),
              _buildSummaryChip(Icons.map_outlined, '$plannedCount planificadas'),
              _buildSummaryChip(Icons.verified_rounded, '$doneCount cerradas'),
              if (_activeTrackingRouteId != null)
                _buildSummaryChip(Icons.gps_fixed_rounded, 'GPS trazando'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _buildAdminActions() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _openCreateRouteSheet,
            icon: const Icon(Icons.add_road_rounded),
            label: const Text('Crear misión'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0F766E),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLegendCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ColorConstants.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ColorConstants.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Como funciona este modo mágico',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: ColorConstants.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.isAdmin
                ? 'Admin crea la misión, elige caminador, origen, destino y paradas. Luego ve el trazado, alertas y evidencia sin borrar historial.'
                : 'Abre la siguiente parada en Waze, activa el trazado GPS y en cada punto sube foto o video. Las alertas quedan guardadas como bitácora permanente.',
            style: const TextStyle(color: ColorConstants.textSecondary, height: 1.45),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final msg = widget.isAdmin
        ? 'No hay misiones creadas todavía. Crea una ruta para empezar a enviar caminadores.'
        : 'Todavía no te han asignado una ruta. Cuando admin te marque una misión, aparecerá aquí.';

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: ColorConstants.cardWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: ColorConstants.divider),
      ),
      child: Column(
        children: [
          const Icon(Icons.explore_off_rounded, size: 44, color: Color(0xFF0F766E)),
          const SizedBox(height: 10),
          const Text(
            'Sin rutas todavía',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(msg, textAlign: TextAlign.center, style: const TextStyle(color: ColorConstants.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildRouteCard(_RouteDoc route) {
    final data = route.data;
    final status = _statusOf(data);
    final stopLabels = _stopLabelsOf(data);
    final completedStops = List<String>.from(data['completedStops'] as List? ?? const []);
    final requiredEvidencePoints = _requiredEvidencePointsOf(data);
    final plannedAlerts = _plannedAlertsOf(data);
    final nextStop = _nextStopLabel(data);
    final isExpanded = _expandedRouteId == route.id;
    final isTrackingThis = _activeTrackingRouteId == route.id;
    final assignedToName = (data['assignedToName'] as String? ?? 'Sin asignar').trim();
    final title = (data['title'] as String? ?? 'Misión sin título').trim();
    final fromLabel = (data['fromLabel'] as String? ?? '-').trim();
    final toLabel = (data['toLabel'] as String? ?? '-').trim();
    final notes = (data['notes'] as String? ?? '').trim();
    final createdAtMs = _createdAtMsOf(data);
    final trackingActive = data['trackingActive'] == true;
    final lastUpdateMs = (data['lastUpdateMs'] as num?)?.toInt() ?? 0;
    final alertCount = (data['alertCount'] as num?)?.toInt() ?? 0;
    final evidenceCount = (data['evidenceCount'] as num?)?.toInt() ?? 0;
    final canOperateThisRoute = _canOperateRoutes &&
        (widget.isAdmin || data['assignedToUserId'] == _currentUserId || data['createdByUserId'] == _currentUserId);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: ColorConstants.cardWhite,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: ColorConstants.divider),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () {
              setState(() {
                _expandedRouteId = isExpanded ? null : route.id;
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: ColorConstants.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$fromLabel  ->  $toLabel',
                              style: const TextStyle(
                                color: ColorConstants.textSecondary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _StatusBadge(status: status),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _InfoPill(icon: Icons.person_outline, text: assignedToName),
                      _InfoPill(icon: Icons.flag_outlined, text: nextStop),
                      _InfoPill(icon: Icons.camera_alt_outlined, text: '$evidenceCount pruebas'),
                      _InfoPill(icon: Icons.crisis_alert_outlined, text: '$alertCount alertas'),
                      if (requiredEvidencePoints.isNotEmpty)
                        _InfoPill(
                          icon: Icons.checklist_rtl_rounded,
                          text: '${requiredEvidencePoints.length} req. evidencia',
                          color: const Color(0xFF1D4ED8),
                        ),
                      if (plannedAlerts.isNotEmpty)
                        _InfoPill(
                          icon: Icons.warning_amber_rounded,
                          text: '${plannedAlerts.length} req. alerta',
                          color: const Color(0xFFB45309),
                        ),
                      if (trackingActive || isTrackingThis)
                        _InfoPill(
                          icon: Icons.gps_fixed_rounded,
                          text: lastUpdateMs > 0 ? 'Trazando ${_ago(lastUpdateMs)}' : 'Trazando ahora',
                          color: const Color(0xFF0F766E),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Creada ${_dateFormat.format(DateTime.fromMillisecondsSinceEpoch(createdAtMs))}',
                          style: const TextStyle(color: ColorConstants.textSecondary, fontSize: 12),
                        ),
                      ),
                      Icon(
                        isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                        color: ColorConstants.textSecondary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            crossFadeState: isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 180),
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (notes.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(notes, style: const TextStyle(height: 1.35)),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _buildMissionRequirementsSection(requiredEvidencePoints, plannedAlerts),
                  const SizedBox(height: 12),
                  _buildActionButtons(route.id, data, canOperateThisRoute, isTrackingThis),
                  const SizedBox(height: 14),
                  _buildStopsSection(route.id, stopLabels, completedStops, canOperateThisRoute),
                  const SizedBox(height: 14),
                  SizedBox(height: 220, child: _RouteMap(routeId: route.id)),
                  const SizedBox(height: 14),
                  _buildRecentEvents(route.id),
                  if (canOperateThisRoute && status != 'completed') ...[
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _busyTracking ? null : () => _finishRoute(route.id),
                        icon: const Icon(Icons.task_alt_rounded),
                        label: const Text('Cerrar misión'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF0F766E),
                          side: const BorderSide(color: Color(0xFF0F766E)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(
    String routeId,
    Map<String, dynamic> data,
    bool canOperateThisRoute,
    bool isTrackingThis,
  ) {
    final nextStop = _nextStopLabel(data);

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        if (canOperateThisRoute)
          ElevatedButton.icon(
            onPressed: _busyTracking ? null : () => _toggleTracking(routeId),
            icon: Icon(isTrackingThis ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded),
            label: Text(isTrackingThis ? 'Detener trazado' : 'Iniciar trazado'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0F766E),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        OutlinedButton.icon(
          onPressed: () => _openWaze(nextStop),
          icon: const Icon(Icons.navigation_rounded),
          label: const Text('Abrir Waze'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF1565C0),
            side: const BorderSide(color: Color(0xFF1565C0)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        OutlinedButton.icon(
          onPressed: () => _openGoogleMaps(nextStop),
          icon: const Icon(Icons.map_outlined),
          label: const Text('Seguir Maps'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF188038),
            side: const BorderSide(color: Color(0xFF188038)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        OutlinedButton.icon(
          onPressed: () => _openMapsMe(data),
          icon: const Icon(Icons.public_rounded),
          label: const Text('Seguir MAPS.ME'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF0A7EA4),
            side: const BorderSide(color: Color(0xFF0A7EA4)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        if (canOperateThisRoute)
          OutlinedButton.icon(
            onPressed: _uploadingEvidence ? null : () => _captureEvidence(routeId, isVideo: false),
            icon: const Icon(Icons.add_a_photo_outlined),
            label: const Text('Foto'),
            style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          ),
        if (canOperateThisRoute)
          OutlinedButton.icon(
            onPressed: _uploadingEvidence ? null : () => _captureEvidence(routeId, isVideo: true),
            icon: const Icon(Icons.videocam_outlined),
            label: const Text('Video'),
            style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          ),
        if (canOperateThisRoute)
          OutlinedButton.icon(
            onPressed: () => _openAlertSheet(routeId),
            icon: const Icon(Icons.add_alert_rounded),
            label: const Text('Alerta'),
            style: OutlinedButton.styleFrom(
              foregroundColor: ColorConstants.dangerRed,
              side: const BorderSide(color: ColorConstants.dangerRed),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
      ],
    );
  }

  Widget _buildMissionRequirementsSection(
    List<Map<String, dynamic>> requiredEvidencePoints,
    List<Map<String, dynamic>> plannedAlerts,
  ) {
    if (requiredEvidencePoints.isEmpty && plannedAlerts.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Text(
          'No hay requisitos detallados cargados por admin para esta misión.',
          style: TextStyle(color: ColorConstants.textSecondary),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Plan de evidencia y alertas',
            style: TextStyle(fontWeight: FontWeight.w800, color: ColorConstants.textPrimary),
          ),
          const SizedBox(height: 8),
          ...requiredEvidencePoints.asMap().entries.map((entry) {
            final idx = entry.key;
            final item = entry.value;
            final type = (item['type'] as String? ?? '').trim().toLowerCase();
            final note = (item['note'] as String? ?? '').trim();
            final kindLabel = type == 'photo'
                ? '📷 Subir foto'
                : (type == 'video' ? '🎥 Subir video' : '📸🎥 Subir foto y video');
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${idx + 1}. $kindLabel${note.isNotEmpty ? ' - $note' : ''}',
                style: const TextStyle(color: ColorConstants.textPrimary, height: 1.35),
              ),
            );
          }),
          if (plannedAlerts.isNotEmpty) ...[
            const SizedBox(height: 4),
            ...plannedAlerts.asMap().entries.map((entry) {
              final idx = entry.key;
              final item = entry.value;
              final type = (item['type'] as String? ?? '').trim().toLowerCase();
              final note = (item['note'] as String? ?? '').trim();
              final kindLabel = type == 'cuidado' ? '⚠️ Cuidado' : '🚨 Peligro';
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${requiredEvidencePoints.length + idx + 1}. $kindLabel${note.isNotEmpty ? ' - $note' : ''}',
                  style: const TextStyle(color: ColorConstants.textPrimary, height: 1.35),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildStopsSection(
    String routeId,
    List<String> stopLabels,
    List<String> completedStops,
    bool canOperateThisRoute,
  ) {
    if (stopLabels.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Text(
          'Esta misión no tiene paradas extra. El caminador puede navegar directo al destino y subir evidencia en cualquier punto.',
          style: TextStyle(color: ColorConstants.textSecondary, height: 1.35),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Paradas y checkpoints',
          style: TextStyle(fontWeight: FontWeight.w800, color: ColorConstants.textPrimary),
        ),
        const SizedBox(height: 10),
        ...List.generate(stopLabels.length, (index) {
          final stop = stopLabels[index];
          final done = completedStops.contains(stop);
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: done ? const Color(0xFFECFDF5) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: done ? const Color(0xFF10B981) : ColorConstants.divider),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: done ? const Color(0xFF10B981) : const Color(0xFFE2E8F0),
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      color: done ? Colors.white : const Color(0xFF334155),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    stop,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Abrir Waze',
                  onPressed: () => _openWaze(stop),
                  icon: const Icon(Icons.navigation_rounded, color: Color(0xFF1565C0)),
                ),
                IconButton(
                  tooltip: 'Seguir en Google Maps',
                  onPressed: () => _openGoogleMaps(stop),
                  icon: const Icon(Icons.map_outlined, color: Color(0xFF188038)),
                ),
                if (canOperateThisRoute)
                  IconButton(
                    tooltip: done ? 'Marcado' : 'Marcar checkpoint',
                    onPressed: done ? null : () => _markCheckpoint(routeId, stop),
                    icon: Icon(
                      done ? Icons.task_alt_rounded : Icons.flag_circle_outlined,
                      color: done ? const Color(0xFF10B981) : const Color(0xFF0F766E),
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildRecentEvents(String routeId) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(_kRoutesCollection)
          .doc(routeId)
          .collection(_kRouteEventsCollection)
          .orderBy('createdAtMs', descending: true)
          .limit(8)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? const [];
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Bitácora persistente',
                style: TextStyle(fontWeight: FontWeight.w800, color: ColorConstants.textPrimary),
              ),
              const SizedBox(height: 8),
              if (docs.isEmpty)
                const Text(
                  'Aún no hay alertas ni evidencias en esta misión.',
                  style: TextStyle(color: ColorConstants.textSecondary),
                )
              else
                ...docs.map((doc) {
                  final data = Map<String, dynamic>.from(doc.data() as Map<String, dynamic>);
                  return _EventTile(
                    data: data,
                    dateFormat: _dateFormat,
                    onOpenMedia: () {
                      final mediaUrl = (data['mediaUrl'] as String? ?? '').trim();
                      final type = (data['type'] as String? ?? '').trim();
                      if (mediaUrl.isEmpty) return;
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => type == 'video'
                              ? FullVideoPage(url: mediaUrl)
                              : FullPhotoPage(url: mediaUrl),
                        ),
                      );
                    },
                  );
                }),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openCreateRouteSheet() async {
    final titleCtrl = TextEditingController();
    final fromCtrl = TextEditingController();
    final toCtrl = TextEditingController();
    final stopsCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    String? selectedUid;
    String? selectedName;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: EdgeInsets.only(
                left: 18,
                right: 18,
                top: 18,
                bottom: MediaQuery.of(context).viewInsets.bottom + 18,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Nueva misión Caminador',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(labelText: 'Titulo de la misión'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: fromCtrl,
                      decoration: const InputDecoration(labelText: 'Origen'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: toCtrl,
                      decoration: const InputDecoration(labelText: 'Destino'),
                    ),
                    const SizedBox(height: 10),
                    StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection(FirestoreConstants.pathUserCollection)
                          .where(FirestoreConstants.rolId, isEqualTo: _kCaminadorRoleId)
                          .snapshots(),
                      builder: (context, snapshot) {
                        final items = snapshot.data?.docs.map((doc) {
                          final data = Map<String, dynamic>.from(doc.data() as Map<String, dynamic>);
                          final name = (data[FirestoreConstants.nickname] as String? ?? 'Caminador').trim();
                          return DropdownMenuItem<String>(
                            value: doc.id,
                            child: Text(name),
                            onTap: () {
                              selectedUid = doc.id;
                              selectedName = name;
                            },
                          );
                        }).toList() ?? <DropdownMenuItem<String>>[];

                        return DropdownButtonFormField<String>(
                          initialValue: items.any((item) => item.value == selectedUid) ? selectedUid : null,
                          decoration: const InputDecoration(labelText: 'Asignar caminador'),
                          items: items,
                          onChanged: (value) {
                            setModalState(() {
                              selectedUid = value;
                              if (value != null) {
                                final match = snapshot.data?.docs.firstWhere((doc) => doc.id == value);
                                if (match != null) {
                                  final data = Map<String, dynamic>.from(match.data() as Map<String, dynamic>);
                                  selectedName = (data[FirestoreConstants.nickname] as String? ?? 'Caminador').trim();
                                }
                              }
                            });
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: stopsCtrl,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Paradas (una por linea)',
                        hintText: 'Brasil\nFrontera\nPeru',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: notesCtrl,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Instrucciones para el caminador',
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final title = titleCtrl.text.trim();
                          final from = fromCtrl.text.trim();
                          final to = toCtrl.text.trim();
                          final notes = notesCtrl.text.trim();
                          final stops = stopsCtrl.text
                              .split('\n')
                              .map((line) => line.trim())
                              .where((line) => line.isNotEmpty)
                              .toList();

                          if (title.isEmpty || from.isEmpty || to.isEmpty || selectedUid == null) {
                            Fluttertoast.showToast(msg: 'Completa titulo, origen, destino y caminador');
                            return;
                          }

                          await FirebaseFirestore.instance.collection(_kRoutesCollection).add({
                            'title': title,
                            'fromLabel': from,
                            'toLabel': to,
                            'stopLabels': stops,
                            'completedStops': <String>[],
                            'notes': notes,
                            'assignedToUserId': selectedUid,
                            'assignedToName': selectedName ?? 'Caminador',
                            'createdByUserId': _currentUserId,
                            'createdByName': _currentNickname,
                            'status': 'planned',
                            'trackingActive': false,
                            'createdAtMs': DateTime.now().millisecondsSinceEpoch,
                            'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
                            'alertCount': 0,
                            'evidenceCount': 0,
                          });

                          if (!context.mounted) return;
                          Navigator.pop(context);
                          Fluttertoast.showToast(msg: 'Misión creada');
                        },
                        icon: const Icon(Icons.add_road_rounded),
                        label: const Text('Guardar misión'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0F766E),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _toggleTracking(String routeId) async {
    if (_busyTracking) return;
    setState(() => _busyTracking = true);

    try {
      if (_activeTrackingRouteId == routeId) {
        await _stopTracking(routeId, markPaused: true);
        Fluttertoast.showToast(msg: 'Trazado detenido');
      } else {
        if (_activeTrackingRouteId != null && _activeTrackingRouteId!.isNotEmpty) {
          await _stopTracking(_activeTrackingRouteId!, markPaused: true);
        }
        final position = await _requirePosition();
        if (position == null) return;

        final routeRef = FirebaseFirestore.instance.collection(_kRoutesCollection).doc(routeId);
        await routeRef.set({
          'status': 'active',
          'trackingActive': true,
          'trackingByUserId': _currentUserId,
          'trackingByName': _currentNickname,
          'lastLat': position.latitude,
          'lastLng': position.longitude,
          'lastUpdateMs': DateTime.now().millisecondsSinceEpoch,
          'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
        }, SetOptions(merge: true));

        await _appendPosition(routeId, position, label: 'Inicio de trazado');
        await _appendEvent(routeId, {
          'type': 'system',
          'title': 'Trazado iniciado',
          'note': '$_currentNickname inició el seguimiento GPS de esta misión.',
        });

        _trackingSub = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 8,
          ),
        ).listen((pos) {
          _appendPosition(routeId, pos);
        });

        await _authProvider.prefs.setString(_kActiveRoutePrefKey, routeId);
        if (mounted) {
          setState(() {
            _activeTrackingRouteId = routeId;
          });
        }
        Fluttertoast.showToast(msg: 'Trazado en vivo activado');
      }
    } catch (e) {
      Fluttertoast.showToast(msg: 'No se pudo manejar el trazado: $e');
    } finally {
      if (mounted) setState(() => _busyTracking = false);
    }
  }

  Future<void> _stopTracking(String routeId, {required bool markPaused}) async {
    await _trackingSub?.cancel();
    _trackingSub = null;
    final position = await _safeCurrentPosition();

    await FirebaseFirestore.instance.collection(_kRoutesCollection).doc(routeId).set({
      'trackingActive': false,
      'lastUpdateMs': DateTime.now().millisecondsSinceEpoch,
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      if (position != null) 'lastLat': position.latitude,
      if (position != null) 'lastLng': position.longitude,
    }, SetOptions(merge: true));

    if (markPaused) {
      await _appendEvent(routeId, {
        'type': 'system',
        'title': 'Trazado pausado',
        'note': '$_currentNickname pausó el seguimiento GPS.',
        if (position != null) 'lat': position.latitude,
        if (position != null) 'lng': position.longitude,
      });
    }

    await _authProvider.prefs.remove(_kActiveRoutePrefKey);
    if (mounted) {
      setState(() {
        _activeTrackingRouteId = null;
      });
    }
  }

  Future<void> _finishRoute(String routeId) async {
    if (_activeTrackingRouteId == routeId) {
      await _stopTracking(routeId, markPaused: false);
    }
    final position = await _safeCurrentPosition();
    await FirebaseFirestore.instance.collection(_kRoutesCollection).doc(routeId).set({
      'status': 'completed',
      'trackingActive': false,
      'completedAtMs': DateTime.now().millisecondsSinceEpoch,
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      if (position != null) 'lastLat': position.latitude,
      if (position != null) 'lastLng': position.longitude,
    }, SetOptions(merge: true));
    await _appendEvent(routeId, {
      'type': 'system',
      'title': 'Misión cerrada',
      'note': '$_currentNickname marcó esta misión como terminada.',
      if (position != null) 'lat': position.latitude,
      if (position != null) 'lng': position.longitude,
    });
    Fluttertoast.showToast(msg: 'Misión cerrada');
  }

  Future<void> _markCheckpoint(String routeId, String stopLabel) async {
    final position = await _requirePosition();
    if (position == null) return;

    await FirebaseFirestore.instance.collection(_kRoutesCollection).doc(routeId).set({
      'completedStops': FieldValue.arrayUnion([stopLabel]),
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      'lastLat': position.latitude,
      'lastLng': position.longitude,
      'lastUpdateMs': DateTime.now().millisecondsSinceEpoch,
    }, SetOptions(merge: true));

    await _appendPosition(routeId, position, label: 'Checkpoint $stopLabel');
    await _appendEvent(routeId, {
      'type': 'checkpoint',
      'title': 'Checkpoint marcado',
      'note': stopLabel,
      'lat': position.latitude,
      'lng': position.longitude,
    });
    Fluttertoast.showToast(msg: 'Checkpoint guardado');
  }

  Future<void> _captureEvidence(String routeId, {required bool isVideo}) async {
    if (_uploadingEvidence) return;
    final caption = await _askForText(
      title: isVideo ? 'Video del punto' : 'Foto del punto',
      hint: 'Ej: frontera cerrada, lluvia, entrega hecha...'
    );
    if (!mounted) return;

    XFile? picked;
    try {
      picked = isVideo
          ? await _picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(minutes: 1))
          : await _picker.pickImage(source: ImageSource.camera, imageQuality: 72);
    } catch (e) {
      Fluttertoast.showToast(msg: 'No se pudo abrir la camara: $e');
      return;
    }

    if (picked == null) return;
    final position = await _requirePosition();
    if (position == null) return;

    setState(() => _uploadingEvidence = true);
    try {
      final file = File(picked.path);
      final now = DateTime.now().millisecondsSinceEpoch;
      final ext = picked.path.split('.').last.toLowerCase();
      final storagePath = 'caminador/routes/$routeId/${isVideo ? 'videos' : 'photos'}/$_currentUserId-$now.$ext';
      final task = FirebaseStorage.instance.ref().child(storagePath).putFile(file);
      final snap = await task;
      final mediaUrl = await snap.ref.getDownloadURL();

      await FirebaseFirestore.instance.collection(_kRoutesCollection).doc(routeId).set({
        'evidenceCount': FieldValue.increment(1),
        'lastLat': position.latitude,
        'lastLng': position.longitude,
        'lastUpdateMs': now,
        'updatedAtMs': now,
      }, SetOptions(merge: true));

      await _appendPosition(routeId, position, label: isVideo ? 'Video subido' : 'Foto subida');
      await _appendEvent(routeId, {
        'type': isVideo ? 'video' : 'photo',
        'title': isVideo ? 'Video del punto' : 'Foto del punto',
        'note': (caption ?? '').trim(),
        'mediaUrl': mediaUrl,
        'lat': position.latitude,
        'lng': position.longitude,
      });
      Fluttertoast.showToast(msg: isVideo ? 'Video subido' : 'Foto subida');
    } catch (e) {
      Fluttertoast.showToast(msg: 'No se pudo subir la evidencia: $e');
    } finally {
      if (mounted) setState(() => _uploadingEvidence = false);
    }
  }

  Future<void> _openAlertSheet(String routeId) async {
    final noteCtrl = TextEditingController();
    int selectedKind = 3;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: EdgeInsets.only(
                left: 18,
                right: 18,
                top: 18,
                bottom: MediaQuery.of(context).viewInsets.bottom + 18,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Nueva alerta de ruta',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _routeAlertKinds.map((kind) {
                      final selected = selectedKind == kind.id;
                      return ChoiceChip(
                        label: Text('${kind.emoji} ${kind.label}'),
                        selected: selected,
                        onSelected: (_) => setModalState(() => selectedKind = kind.id),
                        selectedColor: kind.color.withValues(alpha: 0.18),
                        labelStyle: TextStyle(
                          color: selected ? kind.color : ColorConstants.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Detalle de la alerta',
                      hintText: 'Ej: puente cerrado, policia, peligro, agua, peaje...'
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.pop(context);
                        await _sendRouteAlert(routeId, selectedKind, noteCtrl.text.trim());
                      },
                      icon: const Icon(Icons.crisis_alert_rounded),
                      label: const Text('Guardar alerta'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ColorConstants.dangerRed,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _sendRouteAlert(String routeId, int kindId, String note) async {
    final position = await _requirePosition();
    if (position == null) return;

    final kind = _routeAlertKinds.firstWhere((item) => item.id == kindId, orElse: () => _routeAlertKinds[2]);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final routeSnap = await FirebaseFirestore.instance.collection(_kRoutesCollection).doc(routeId).get();
    final routeData = Map<String, dynamic>.from(routeSnap.data() ?? const {});
    final routeTitle = (routeData['title'] as String? ?? 'Ruta caminador').trim();

    await FirebaseFirestore.instance.collection(_kRoutesCollection).doc(routeId).set({
      'alertCount': FieldValue.increment(1),
      'lastLat': position.latitude,
      'lastLng': position.longitude,
      'lastUpdateMs': ts,
      'updatedAtMs': ts,
    }, SetOptions(merge: true));

    await _appendPosition(routeId, position, label: 'Alerta ${kind.label}');
    await _appendEvent(routeId, {
      'type': 'alert',
      'title': kind.label,
      'note': note,
      'alertKind': kind.id,
      'alertEmoji': kind.emoji,
      'lat': position.latitude,
      'lng': position.longitude,
    });

    await FirebaseFirestore.instance.collection('alerts').doc('${routeId}_$ts').set({
      'alertKind': kind.id,
      'lat': position.latitude,
      'lng': position.longitude,
      'groupId': routeId,
      'groupName': routeTitle,
      'senderId': _currentUserId,
      'senderName': _currentNickname,
      'ts': ts,
      'expireAt': ts + _kPersistentAlertTtlMs,
      'routeAlert': true,
      'note': note,
    });

    Fluttertoast.showToast(msg: '${kind.emoji} Alerta guardada');
  }

  Future<void> _appendPosition(String routeId, Position position, {String? label}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final routeRef = FirebaseFirestore.instance.collection(_kRoutesCollection).doc(routeId);
    await routeRef.collection(_kRoutePositionsCollection).doc(now.toString()).set({
      'lat': position.latitude,
      'lng': position.longitude,
      'accuracy': position.accuracy,
      'speed': position.speed,
      'createdAtMs': now,
      'label': label ?? '',
      'userId': _currentUserId,
      'userName': _currentNickname,
    });
    await routeRef.set({
      'lastLat': position.latitude,
      'lastLng': position.longitude,
      'lastUpdateMs': now,
      'updatedAtMs': now,
    }, SetOptions(merge: true));
  }

  Future<void> _appendEvent(String routeId, Map<String, dynamic> payload) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await FirebaseFirestore.instance
        .collection(_kRoutesCollection)
        .doc(routeId)
        .collection(_kRouteEventsCollection)
        .doc(now.toString())
        .set({
      'createdAtMs': now,
      'userId': _currentUserId,
      'userName': _currentNickname,
      ...payload,
    });
  }

  Future<Position?> _requirePosition() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        Fluttertoast.showToast(msg: 'Activa el GPS para seguir la ruta');
        return null;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        Fluttertoast.showToast(msg: 'Permiso de ubicación denegado');
        return null;
      }
      return Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error GPS: $e');
      return null;
    }
  }

  Future<Position?> _safeCurrentPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _openWaze(String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) {
      Fluttertoast.showToast(msg: 'Esta misión no tiene un destino util para Waze');
      return;
    }
    final q = Uri.encodeComponent(trimmed);
    final uri = Uri.parse('https://waze.com/ul?q=$q&navigate=yes');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      Fluttertoast.showToast(msg: 'No se pudo abrir Waze');
    }
  }

  Future<void> _openGoogleMaps(String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) {
      Fluttertoast.showToast(msg: 'Esta misión no tiene un destino util para Google Maps');
      return;
    }
    final q = Uri.encodeComponent(trimmed);
    final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$q&travelmode=driving');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      Fluttertoast.showToast(msg: 'No se pudo abrir Google Maps');
    }
  }

  Future<void> _openMapsMe(Map<String, dynamic> data) async {
    final destination = _routeDestinationPointOf(data);
    if (destination == null) {
      Fluttertoast.showToast(msg: 'La misión no tiene coordenadas para abrir en MAPS.ME');
      return;
    }

    final lat = destination['lat']!;
    final lng = destination['lng']!;
    final name = Uri.encodeComponent(_nextStopLabel(data));
    final ll = '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';

    final openCandidates = <Uri>[
      Uri.parse('mapswithme://map?v=2&ll=$ll&n=$name'),
      Uri.parse('https://maps.me/map?v=2&ll=$ll&n=$name'),
    ];

    for (final uri in openCandidates) {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (opened) return;
    }

    final storeCandidates = <Uri>[
      Uri.parse('market://details?id=com.mapswithme.maps.pro'),
      Uri.parse('https://play.google.com/store/apps/details?id=com.mapswithme.maps.pro'),
      Uri.parse('https://play.google.com/store/apps/details?id=com.mapswithme.maps'),
    ];

    for (final uri in storeCandidates) {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (opened) {
        Fluttertoast.showToast(msg: 'Instala MAPS.ME para seguir esta ruta');
        return;
      }
    }

    Fluttertoast.showToast(msg: 'No se pudo abrir MAPS.ME ni Play Store');
  }

  Future<String?> _askForText({required String title, required String hint}) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: ctrl,
            decoration: InputDecoration(hintText: hint),
            minLines: 2,
            maxLines: 4,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Omitir')),
            ElevatedButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Guardar')),
          ],
        );
      },
    );
  }

  List<String> _stopLabelsOf(Map<String, dynamic> data) {
    return List<String>.from(data['stopLabels'] as List? ?? const []);
  }

  List<Map<String, dynamic>> _requiredEvidencePointsOf(Map<String, dynamic> data) {
    final raw = data['requiredEvidencePoints'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  List<Map<String, dynamic>> _plannedAlertsOf(Map<String, dynamic> data) {
    final raw = data['plannedAlerts'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Map<String, double>? _routeDestinationPointOf(Map<String, dynamic> data) {
    final routePath = data['routePath'];
    if (routePath is List) {
      for (var i = routePath.length - 1; i >= 0; i--) {
        final point = _latLngPointOf(routePath[i]);
        if (point != null) return point;
      }
    }

    final fallbackLat = _doubleOf(data['lastLat']);
    final fallbackLng = _doubleOf(data['lastLng']);
    if (fallbackLat != null && fallbackLng != null) {
      return {'lat': fallbackLat, 'lng': fallbackLng};
    }

    return null;
  }

  Map<String, double>? _latLngPointOf(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final lat = _doubleOf(map['lat']);
    final lng = _doubleOf(map['lng']);
    if (lat == null || lng == null) return null;
    return {'lat': lat, 'lng': lng};
  }

  double? _doubleOf(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  String _nextStopLabel(Map<String, dynamic> data) {
    final completed = List<String>.from(data['completedStops'] as List? ?? const []);
    for (final stop in _stopLabelsOf(data)) {
      if (!completed.contains(stop)) return stop;
    }
    final toLabel = (data['toLabel'] as String? ?? '').trim();
    return toLabel.isEmpty ? 'Destino libre' : toLabel;
  }

  int _createdAtMsOf(Map<String, dynamic> data) {
    return (data['createdAtMs'] as num?)?.toInt() ?? 0;
  }

  String _statusOf(Map<String, dynamic> data) {
    final raw = (data['status'] as String? ?? 'planned').trim();
    if (raw.isEmpty) return 'planned';
    return raw;
  }

  String _ago(int timestampMs) {
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(timestampMs));
    if (diff.inSeconds < 60) return 'hace ${diff.inSeconds}s';
    if (diff.inMinutes < 60) return 'hace ${diff.inMinutes}min';
    if (diff.inHours < 24) return 'hace ${diff.inHours}h';
    return 'hace ${diff.inDays}d';
  }
}

class _RouteDoc {
  const _RouteDoc({required this.id, required this.data});

  final String id;
  final Map<String, dynamic> data;
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tone = color ?? const Color(0xFF334155);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: tone),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(color: tone, fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    String label;
    switch (status) {
      case 'active':
        bg = const Color(0xFFDCFCE7);
        fg = const Color(0xFF166534);
        label = 'Activa';
        break;
      case 'completed':
        bg = const Color(0xFFDBEAFE);
        fg = const Color(0xFF1D4ED8);
        label = 'Cerrada';
        break;
      default:
        bg = const Color(0xFFFFF7ED);
        fg = const Color(0xFFEA580C);
        label = 'Planificada';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 12)),
    );
  }
}

class _RouteMap extends StatelessWidget {
  const _RouteMap({required this.routeId});

  final String routeId;

  @override
  Widget build(BuildContext context) {
    final routeRef = FirebaseFirestore.instance.collection(_kRoutesCollection).doc(routeId);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: ColoredBox(
        color: const Color(0xFFF1F5F9),
        child: StreamBuilder<QuerySnapshot>(
          stream: routeRef.collection(_kRoutePositionsCollection).orderBy('createdAtMs').limitToLast(120).snapshots(),
          builder: (context, positionSnap) {
            final positions = positionSnap.data?.docs.map((doc) {
              final data = Map<String, dynamic>.from(doc.data() as Map<String, dynamic>);
              final lat = (data['lat'] as num?)?.toDouble();
              final lng = (data['lng'] as num?)?.toDouble();
              if (lat == null || lng == null) return null;
              return LatLng(lat, lng);
            }).whereType<LatLng>().toList() ?? <LatLng>[];

            return StreamBuilder<QuerySnapshot>(
              stream: routeRef.collection(_kRouteEventsCollection).orderBy('createdAtMs', descending: true).limit(25).snapshots(),
              builder: (context, eventSnap) {
                final eventMarkers = eventSnap.data?.docs.map((doc) {
                  final data = Map<String, dynamic>.from(doc.data() as Map<String, dynamic>);
                  final lat = (data['lat'] as num?)?.toDouble();
                  final lng = (data['lng'] as num?)?.toDouble();
                  if (lat == null || lng == null) return null;
                  return Marker(
                    point: LatLng(lat, lng),
                    width: 38,
                    height: 38,
                    child: _markerForType(data['type'] as String? ?? 'system'),
                  );
                }).whereType<Marker>().toList() ?? <Marker>[];

                if (positions.isEmpty && eventMarkers.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        'El mapa se irá dibujando cuando el caminador active el trazado o registre un punto.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: ColorConstants.textSecondary, height: 1.4),
                      ),
                    ),
                  );
                }

                final center = positions.isNotEmpty
                    ? positions.last
                    : eventMarkers.first.point;

                return FlutterMap(
                  options: MapOptions(initialCenter: center, initialZoom: 15),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.dfa.flutterchatdemo',
                    ),
                    if (positions.length >= 2)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: positions,
                            strokeWidth: 5,
                            color: const Color(0xFF0F766E),
                          ),
                        ],
                      ),
                    if (positions.isNotEmpty)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: positions.first,
                            width: 28,
                            height: 28,
                            child: const Icon(Icons.trip_origin, color: Color(0xFF2563EB), size: 24),
                          ),
                          Marker(
                            point: positions.last,
                            width: 34,
                            height: 34,
                            child: const Icon(Icons.my_location_rounded, color: Color(0xFF0F766E), size: 28),
                          ),
                        ],
                      ),
                    if (eventMarkers.isNotEmpty) MarkerLayer(markers: eventMarkers),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _markerForType(String type) {
    switch (type) {
      case 'photo':
        return Container(
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          child: const Icon(Icons.camera_alt_rounded, color: Color(0xFF2563EB), size: 24),
        );
      case 'video':
        return Container(
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          child: const Icon(Icons.videocam_rounded, color: Color(0xFF7C3AED), size: 24),
        );
      case 'alert':
        return Container(
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          child: const Icon(Icons.crisis_alert_rounded, color: ColorConstants.dangerRed, size: 24),
        );
      case 'checkpoint':
        return Container(
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          child: const Icon(Icons.flag_circle_rounded, color: Color(0xFF0F766E), size: 24),
        );
      default:
        return Container(
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          child: const Icon(Icons.circle_notifications_rounded, color: Color(0xFF334155), size: 22),
        );
    }
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.data,
    required this.dateFormat,
    required this.onOpenMedia,
  });

  final Map<String, dynamic> data;
  final DateFormat dateFormat;
  final VoidCallback onOpenMedia;

  @override
  Widget build(BuildContext context) {
    final type = (data['type'] as String? ?? 'system').trim();
    final title = (data['title'] as String? ?? 'Evento').trim();
    final note = (data['note'] as String? ?? '').trim();
    final userName = (data['userName'] as String? ?? 'Usuario').trim();
    final createdAtMs = (data['createdAtMs'] as num?)?.toInt() ?? 0;
    final mediaUrl = (data['mediaUrl'] as String? ?? '').trim();
    final icon = _iconForType(type);
    final color = _colorForType(type);

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    Text(
                      createdAtMs > 0
                          ? dateFormat.format(DateTime.fromMillisecondsSinceEpoch(createdAtMs))
                          : '-',
                      style: const TextStyle(fontSize: 11, color: ColorConstants.textSecondary),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  userName,
                  style: const TextStyle(fontSize: 12, color: ColorConstants.textSecondary),
                ),
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(note, style: const TextStyle(height: 1.35)),
                ],
                if (mediaUrl.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: onOpenMedia,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.open_in_new_rounded, size: 16, color: Color(0xFF2563EB)),
                        SizedBox(width: 6),
                        Text(
                          'Ver evidencia',
                          style: TextStyle(
                            color: Color(0xFF2563EB),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'photo':
        return Icons.camera_alt_rounded;
      case 'video':
        return Icons.videocam_rounded;
      case 'alert':
        return Icons.crisis_alert_rounded;
      case 'checkpoint':
        return Icons.flag_circle_rounded;
      default:
        return Icons.circle_notifications_rounded;
    }
  }

  Color _colorForType(String type) {
    switch (type) {
      case 'photo':
        return const Color(0xFF2563EB);
      case 'video':
        return const Color(0xFF7C3AED);
      case 'alert':
        return ColorConstants.dangerRed;
      case 'checkpoint':
        return const Color(0xFF0F766E);
      default:
        return const Color(0xFF334155);
    }
  }
}

class _RouteAlertKind {
  const _RouteAlertKind(this.id, this.emoji, this.label, this.color);

  final int id;
  final String emoji;
  final String label;
  final Color color;
}

const List<_RouteAlertKind> _routeAlertKinds = [
  _RouteAlertKind(1, '🚔', 'Control policial', Color(0xFF2563EB)),
  _RouteAlertKind(2, '⚠️', 'Accidente', Color(0xFFEAB308)),
  _RouteAlertKind(3, '🚨', 'Peligro', Color(0xFFEF4444)),
  _RouteAlertKind(4, '🚧', 'Tráfico o bloqueo', Color(0xFFF97316)),
  _RouteAlertKind(5, '📸', 'Punto documentado', Color(0xFF0F766E)),
];
