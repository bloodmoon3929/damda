import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../data/database.dart';
import '../data/database_repository.dart';
import '../providers.dart';
import '../ui/theme.dart';

/// OpenStreetMap asks apps to identify themselves.
const _userAgent = 'kr.bloodmoon.notes/1.0 (personal notes app)';
const _accent = Color(0xFF2383E2);

/// A 장소 cell: `{address, lat, lng}`.
class Place {
  const Place(this.address, this.lat, this.lng, {this.name});

  static Place? fromCell(Object? v) {
    if (v is! Map) return null;
    final lat = (v['lat'] as num?)?.toDouble();
    final lng = (v['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return Place(
      v['address'] as String? ?? '',
      lat,
      lng,
      name: v['name'] as String?,
    );
  }

  /// A place's own name (e.g. a hotel), when it has one besides the address.
  final String? name;
  final String address;
  final double lat;
  final double lng;

  LatLng get latLng => LatLng(lat, lng);

  Map<String, Object> toJson() => {
    'address': address,
    'lat': lat,
    'lng': lng,
    'name': ?name,
  };
}

TileLayer _tiles() => TileLayer(
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  userAgentPackageName: 'kr.bloodmoon.notes',
);

Widget _attribution(BuildContext context) => Positioned(
  right: 4,
  bottom: 4,
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    color: Colors.white70,
    child: const Text(
      '© OpenStreetMap contributors',
      style: TextStyle(fontSize: 10, color: Colors.black87),
    ),
  ),
);

/// Address search (OpenStreetMap Nominatim). Sends [query] to that service.
Future<List<Place>> geocode(String query) async {
  final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
    'q': query,
    'format': 'jsonv2',
    'limit': '6',
    'accept-language': 'ko',
  });
  final res = await http.get(uri, headers: {'User-Agent': _userAgent});
  if (res.statusCode != 200) throw Exception('검색 실패 (${res.statusCode})');
  final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
  return [
    for (final r in list.cast<Map>())
      Place(
        r['display_name'] as String? ?? '',
        double.parse('${r['lat']}'),
        double.parse('${r['lon']}'),
      ),
  ];
}

/// Pick a place: search an address, or click the map. Returns the new value,
/// `null` when cancelled, or an empty map to clear.
Future<Map<String, Object>?> showPlacePicker(
  BuildContext context,
  Place? current,
) {
  return showDialog<Map<String, Object>>(
    context: context,
    builder: (_) => _PlacePicker(initial: current),
  );
}

class _PlacePicker extends StatefulWidget {
  const _PlacePicker({this.initial});

  final Place? initial;

  @override
  State<_PlacePicker> createState() => _PlacePickerState();
}

class _PlacePickerState extends State<_PlacePicker> {
  final _query = TextEditingController();
  final _map = MapController();
  late Place? _place = widget.initial;
  List<Place> _results = const [];
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    _map.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await geocode(q);
      if (!mounted) return;
      setState(() {
        _results = results;
        if (results.isEmpty) _error = '검색 결과가 없어요';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '검색할 수 없어요 (인터넷 연결 확인)');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _choose(Place p) {
    setState(() {
      _place = p;
      _results = const [];
    });
    _map.move(p.latLng, 15);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.noteColors;
    final place = _place;
    return AlertDialog(
      title: const Text('장소'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: InputDecoration(
                isDense: true,
                hintText: '주소나 장소 이름 검색',
                border: const OutlineInputBorder(),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.search),
                        onPressed: _search,
                      ),
              ),
              onSubmitted: (_) => _search(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!, style: TextStyle(color: colors.textMuted)),
              ),
            if (_results.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in _results)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.place_outlined, size: 18),
                        title: Text(
                          r.address,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _choose(r),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(
              height: 280,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter:
                        place?.latLng ?? const LatLng(37.5665, 126.978),
                    initialZoom: place == null ? 5 : 15,
                    // Click the map to put the pin there.
                    onTap: (_, point) => setState(
                      () => _place = Place(
                        '${point.latitude.toStringAsFixed(5)}, '
                        '${point.longitude.toStringAsFixed(5)}',
                        point.latitude,
                        point.longitude,
                      ),
                    ),
                  ),
                  children: [
                    _tiles(),
                    if (place != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: place.latLng,
                            width: 40,
                            height: 40,
                            alignment: Alignment.topCenter,
                            child: const Icon(
                              Icons.location_on,
                              size: 40,
                              color: Color(0xFFE03E3E),
                            ),
                          ),
                        ],
                      ),
                    _attribution(context),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              place == null ? '검색하거나 지도를 눌러 위치를 정하세요' : '📍 ${place.address}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: colors.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.initial != null)
          TextButton(
            onPressed: () => Navigator.pop(context, <String, Object>{}),
            child: const Text('지우기'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: place == null
              ? null
              : () => Navigator.pop(context, place.toJson()),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

/// Items with a 장소 shown as pins; tap a pin to open the item.
class MapDbView extends ConsumerWidget {
  const MapDbView({
    super.key,
    required this.snap,
    required this.view,
    required this.rows,
    required this.onChoosePlace,
  });

  final DbSnapshot snap;
  final DbView view;
  final List<PageRow> rows;
  final VoidCallback onChoosePlace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.noteColors;
    final prop = view.placeBy == null ? null : snap.property(view.placeBy!);
    if (prop == null || prop.type != PropType.place) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              '지도는 장소 속성으로 항목을 표시해요.',
              style: TextStyle(color: colors.textMuted),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: onChoosePlace,
              child: const Text('장소 속성 고르기'),
            ),
          ],
        ),
      );
    }
    final pins = <(PageRow, Place)>[
      for (final r in rows)
        if (Place.fromCell(snap.cell(r.id, prop.id)) case final p?) (r, p),
    ];
    final missing = rows.length - pins.length;

    final MapOptions options;
    if (pins.length >= 2) {
      options = MapOptions(
        initialCameraFit: CameraFit.coordinates(
          coordinates: [for (final (_, p) in pins) p.latLng],
          padding: const EdgeInsets.all(48),
          maxZoom: 16,
        ),
      );
    } else {
      options = MapOptions(
        initialCenter: pins.isEmpty
            ? const LatLng(37.5665, 126.978)
            : pins.first.$2.latLng,
        initialZoom: pins.isEmpty ? 5 : 14,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            '${prop.name} · 핀 ${pins.length}개'
            '${missing > 0 ? ' · 장소 없음 $missing' : ''}',
            style: TextStyle(fontSize: 12, color: colors.textMuted),
          ),
        ),
        SizedBox(
          height: 460,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: FlutterMap(
              // Re-fit when the set of pins changes.
              key: ValueKey(pins.map((e) => e.$1.id).join(',')),
              options: options,
              children: [
                _tiles(),
                MarkerLayer(
                  markers: [
                    for (final (row, place) in pins)
                      Marker(
                        point: place.latLng,
                        width: 160,
                        height: 64,
                        alignment: Alignment.topCenter,
                        child: GestureDetector(
                          onTap: () => ref
                              .read(screenProvider.notifier)
                              .openPage(row.id),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(4),
                                    boxShadow: const [
                                      BoxShadow(
                                        blurRadius: 2,
                                        color: Colors.black26,
                                      ),
                                    ],
                                  ),
                                  child: Text(
                                    row.title.isEmpty ? '제목 없음' : row.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.location_on,
                                  size: 34,
                                  color: _accent,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                _attribution(context),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
