import 'dart:async';

import 'package:flutter/material.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await AndroidAlarmManager.initialize();
  final permissionsGranted = await requestPermissions();
  if (permissionsGranted) {
    await LocationSyncService.instance
        .start(userId: LocationSyncService.defaultUserId);
  }
  runApp(const MyApp());
}

// Request permissions
Future<bool> requestPermissions() async {
  final phoneStatus = await Permission.phone.request();
  final locationStatus = await Permission.location.request();

  return phoneStatus.isGranted &&
      (locationStatus.isGranted || locationStatus.isLimited);
}

// Background call
@pragma('vm:entry-point')
Future<void> _triggerCall(dynamic params) async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Firebase.apps.isEmpty) {
    try {
      await Firebase.initializeApp();
    } catch (error) {
      debugPrint('⚠️ Failed to initialize Firebase in background: $error');
    }
  }

  if (params is! Map<String, dynamic>) {
    debugPrint('⚠️ Invalid parameters received for scheduled call: $params');
    return;
  }

  final phoneNumber = params['phoneNumber'] as String?;
  if (phoneNumber == null || phoneNumber.isEmpty) {
    debugPrint('⚠️ No phone number provided for scheduled call.');
    return;
  }

  final String? sharedUserIdParam = params['sharedUserId'] as String?;
  final double? remoteLatParam =
      (params['remoteLat'] is num) ? (params['remoteLat'] as num).toDouble() : null;
  final double? remoteLngParam =
      (params['remoteLng'] is num) ? (params['remoteLng'] as num).toDouble() : null;

  final SharedPreferences prefs = await SharedPreferences.getInstance();
  RemoteLocationData? cachedRemote = _remoteLocationFromPrefs(prefs);
  RemoteLocationData? remoteLocation;

  final String? querySharedId = sharedUserIdParam ??
      cachedRemote?.sharedUserId ??
      prefs.getString(_prefsRemoteSharedUserIdKey);

  try {
    remoteLocation = await fetchRemoteLocationForPhone(
      phoneNumber,
      sharedUserId: querySharedId,
    );
  } catch (error) {
    debugPrint('⚠️ Error fetching remote location in background: $error');
  }

  if (remoteLocation == null && remoteLatParam != null && remoteLngParam != null) {
    remoteLocation = RemoteLocationData(
      latitude: remoteLatParam,
      longitude: remoteLngParam,
      lastUpdated: DateTime.now(),
      sharedUserId: querySharedId,
    );
  }

  remoteLocation ??= cachedRemote;

  if (remoteLocation != null) {
    await persistRemoteLocation(remoteLocation, prefs: prefs);
    final String staleSuffix = remoteLocation.isStale ? ' (stale)' : '';
    debugPrint(
      'ℹ️ Remote location for $phoneNumber: '
      '${remoteLocation.latitude.toStringAsFixed(5)}, '
      '${remoteLocation.longitude.toStringAsFixed(5)}$staleSuffix',
    );
  } else {
    debugPrint('⚠️ No remote location available for $phoneNumber');
  }

  final Uri telUri = Uri(scheme: 'tel', path: phoneNumber);

  if (await Permission.phone.isGranted) {
    await launchUrl(telUri, mode: LaunchMode.externalApplication);
    debugPrint("📞 Direct call placed to $phoneNumber");
  } else {
    await launchUrl(telUri, mode: LaunchMode.externalApplication);
    debugPrint("📞 Dialer opened for $phoneNumber");
  }
}

// Get current location
Future<Position> getCurrentLocation() async {
  final permissionStatus = await Permission.location.request();

  if (!permissionStatus.isGranted && !permissionStatus.isLimited) {
    throw PermissionDeniedException('Location permission denied');
  }

  final serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    throw const LocationServiceDisabledException();
  }

  const locationSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
  );

  return Geolocator.getCurrentPosition(locationSettings: locationSettings);
}

const List<String> _remoteLocationCollections = <String>[
  'calleeLocations',
  'remoteLocations',
  'users',
];

const Duration _remoteLocationStaleDuration = Duration(minutes: 15);
const String _prefsRemoteLatKey = 'remoteLocation.lat';
const String _prefsRemoteLngKey = 'remoteLocation.lng';
const String _prefsRemoteUpdatedAtKey = 'remoteLocation.updatedAt';
const String _prefsRemoteSharedUserIdKey = 'remoteLocation.sharedUserId';

class RemoteLocationData {
  const RemoteLocationData({
    required this.latitude,
    required this.longitude,
    this.lastUpdated,
    this.sharedUserId,
  });

  final double latitude;
  final double longitude;
  final DateTime? lastUpdated;
  final String? sharedUserId;

  bool get isStale =>
      lastUpdated != null &&
      DateTime.now().difference(lastUpdated!) > _remoteLocationStaleDuration;
}

String _sanitizePhoneNumber(String value) {
  return value.replaceAll(RegExp(r'[^0-9+]'), '');
}

double? _toDouble(dynamic value) {
  if (value is double) {
    return value;
  }
  if (value is int) {
    return value.toDouble();
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

DateTime? _parseTimestamp(dynamic value) {
  if (value is Timestamp) {
    return value.toDate();
  }
  if (value is DateTime) {
    return value;
  }
  if (value is String) {
    return DateTime.tryParse(value);
  }
  if (value is num) {
    final int numericValue = value.toInt();
    if (numericValue > 1000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(numericValue);
    }
    if (numericValue > 1000000000) {
      return DateTime.fromMillisecondsSinceEpoch(numericValue * 1000);
    }
    return DateTime.fromMillisecondsSinceEpoch(numericValue);
  }
  return null;
}

RemoteLocationData? _documentToRemoteLocation(
  DocumentSnapshot<Map<String, dynamic>> snapshot,
) {
  final Map<String, dynamic>? data = snapshot.data();
  if (data == null) {
    return null;
  }

  double? latitude = _toDouble(data['lat'] ?? data['latitude'] ?? data['y']);
  double? longitude =
      _toDouble(data['lng'] ?? data['longitude'] ?? data['long'] ?? data['lon']);

  final dynamic latLngField = data['latLng'];
  if ((latitude == null || longitude == null) && latLngField is Map) {
    final Map<dynamic, dynamic> latLngMap = latLngField;
    latitude ??= _toDouble(latLngMap['lat'] ?? latLngMap['latitude']);
    longitude ??=
        _toDouble(latLngMap['lng'] ?? latLngMap['longitude'] ?? latLngMap['long']);
  }

  final dynamic locationField =
      data['location'] ?? data['position'] ?? data['geo'] ?? data['coordinates'];
  if ((latitude == null || longitude == null) && locationField is GeoPoint) {
    latitude ??= locationField.latitude;
    longitude ??= locationField.longitude;
  } else if ((latitude == null || longitude == null) && locationField is Map) {
    final Map<dynamic, dynamic> locationMap = locationField;
    latitude ??=
        _toDouble(locationMap['lat'] ?? locationMap['latitude'] ?? locationMap['y']);
    longitude ??=
        _toDouble(locationMap['lng'] ?? locationMap['longitude'] ?? locationMap['long'] ?? locationMap['x']);
  }

  if (latitude == null || longitude == null) {
    return null;
  }

  final DateTime? lastUpdated = _parseTimestamp(
    data['updatedAt'] ??
        data['lastUpdated'] ??
        data['timestamp'] ??
        data['lastSeen'] ??
        data['lastLocationUpdate'],
  );

  final dynamic sharedIdValue =
      data['sharedUserId'] ?? data['userId'] ?? data['uid'] ?? data['calleeId'];

  return RemoteLocationData(
    latitude: latitude,
    longitude: longitude,
    lastUpdated: lastUpdated,
    sharedUserId: sharedIdValue is String ? sharedIdValue : null,
  );
}

Future<DocumentSnapshot<Map<String, dynamic>>?> _getDocIfExists(
  CollectionReference<Map<String, dynamic>> collection,
  String docId,
) async {
  if (docId.isEmpty) {
    return null;
  }

  try {
    final doc = await collection.doc(docId).get();
    if (doc.exists) {
      return doc;
    }
  } on FirebaseException catch (error) {
    debugPrint(
      'Firestore document lookup failed for $docId in ${collection.path}: ${error.message}',
    );
  }

  return null;
}

Future<DocumentSnapshot<Map<String, dynamic>>?> _queryForField(
  CollectionReference<Map<String, dynamic>> collection,
  String field,
  String value,
) async {
  if (value.isEmpty) {
    return null;
  }

  try {
    final querySnapshot =
        await collection.where(field, isEqualTo: value).limit(1).get();
    if (querySnapshot.docs.isNotEmpty) {
      return querySnapshot.docs.first;
    }
  } on FirebaseException catch (error) {
    debugPrint(
      'Firestore query failed for $field=$value in ${collection.path}: ${error.message}',
    );
  }

  return null;
}

Future<RemoteLocationData?> fetchRemoteLocationForPhone(
  String phoneNumber, {
  String? sharedUserId,
}) async {
  final String trimmed = phoneNumber.trim();
  final String sanitized = _sanitizePhoneNumber(trimmed);

  final List<String> candidateDocIds = <String>{
    if (sharedUserId != null && sharedUserId.isNotEmpty) sharedUserId,
    if (trimmed.isNotEmpty) trimmed,
    if (sanitized.isNotEmpty) sanitized,
  }.toList();

  for (final collectionName in _remoteLocationCollections) {
    final collection = FirebaseFirestore.instance.collection(collectionName);

    for (final candidate in candidateDocIds) {
      final doc = await _getDocIfExists(collection, candidate);
      if (doc != null) {
        final result = _documentToRemoteLocation(doc);
        if (result != null) {
          return result;
        }
      }
    }

    DocumentSnapshot<Map<String, dynamic>>? queriedDoc;
    final Set<String> attemptedQueries = <String>{};

    Future<DocumentSnapshot<Map<String, dynamic>>?> runQuery(
      String field,
      String value,
    ) {
      if (value.isEmpty) {
        return Future<DocumentSnapshot<Map<String, dynamic>>?>.value(null);
      }
      final signature = '$field::$value';
      if (!attemptedQueries.add(signature)) {
        return Future<DocumentSnapshot<Map<String, dynamic>>?>.value(null);
      }
      return _queryForField(collection, field, value);
    }

    if (sharedUserId != null && sharedUserId.isNotEmpty) {
      queriedDoc = await runQuery('sharedUserId', sharedUserId) ??
          await runQuery('userId', sharedUserId) ??
          await runQuery('uid', sharedUserId) ??
          await runQuery('calleeId', sharedUserId);
    }

    if (queriedDoc == null && trimmed.isNotEmpty) {
      queriedDoc = await runQuery('phoneNumber', trimmed) ??
          await runQuery('normalizedPhoneNumber', trimmed);
    }

    if (queriedDoc == null && sanitized.isNotEmpty && sanitized != trimmed) {
      queriedDoc = await runQuery('phoneNumber', sanitized) ??
          await runQuery('normalizedPhoneNumber', sanitized);
    }

    if (queriedDoc != null) {
      final result = _documentToRemoteLocation(queriedDoc);
      if (result != null) {
        return result;
      }
    }
  }

  return null;
}

Future<void> persistRemoteLocation(
  RemoteLocationData data, {
  SharedPreferences? prefs,
}) async {
  final SharedPreferences store = prefs ?? await SharedPreferences.getInstance();
  await store.setDouble(_prefsRemoteLatKey, data.latitude);
  await store.setDouble(_prefsRemoteLngKey, data.longitude);
  if (data.lastUpdated != null) {
    await store.setString(
      _prefsRemoteUpdatedAtKey,
      data.lastUpdated!.toIso8601String(),
    );
  } else {
    await store.remove(_prefsRemoteUpdatedAtKey);
  }

  final String? sharedId = data.sharedUserId;
  if (sharedId != null && sharedId.isNotEmpty) {
    await store.setString(_prefsRemoteSharedUserIdKey, sharedId);
  } else {
    await store.remove(_prefsRemoteSharedUserIdKey);
  }
}

Future<RemoteLocationData?> readPersistedRemoteLocation({
  SharedPreferences? prefs,
}) async {
  final SharedPreferences store = prefs ?? await SharedPreferences.getInstance();
  return _remoteLocationFromPrefs(store);
}

RemoteLocationData? _remoteLocationFromPrefs(SharedPreferences prefs) {
  final double? lat = prefs.getDouble(_prefsRemoteLatKey);
  final double? lng = prefs.getDouble(_prefsRemoteLngKey);
  if (lat == null || lng == null) {
    return null;
  }
  final String? updatedAtIso = prefs.getString(_prefsRemoteUpdatedAtKey);
  final DateTime? updatedAt =
      updatedAtIso != null ? DateTime.tryParse(updatedAtIso) : null;
  final String? sharedId = prefs.getString(_prefsRemoteSharedUserIdKey);
  return RemoteLocationData(
    latitude: lat,
    longitude: lng,
    lastUpdated: updatedAt,
    sharedUserId: sharedId,
  );
}

String _formatTimestamp(DateTime? timestamp) {
  if (timestamp == null) {
    return 'unknown';
  }
  final DateTime local = timestamp.toLocal();
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}

// Main App
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Call Reminder App",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const CallSchedulerScreen(),
    );
  }
}

class CallSchedulerScreen extends StatefulWidget {
  const CallSchedulerScreen({super.key});

  @override
  State<CallSchedulerScreen> createState() => _CallSchedulerScreenState();
}

class _CallSchedulerScreenState extends State<CallSchedulerScreen> {
  final TextEditingController _phoneController = TextEditingController();
  TimeOfDay? _selectedTime;
  String _locationMessage = "📍 Location not fetched";
  LatLng? _currentLatLng;
  bool _isFetchingLocation = false;
  bool _isLoadingRemoteLocation = false;
  String? _sharedRemoteUserId;

  @override
  void initState() {
    super.initState();
    _restoreCachedRemoteLocation();
    unawaited(LocationSyncService.instance
        .start(userId: LocationSyncService.defaultUserId));
  }

  Future<void> _restoreCachedRemoteLocation() async {
    final RemoteLocationData? cached = await readPersistedRemoteLocation();
    if (cached == null || !mounted) {
      return;
    }

    setState(() {
      _currentLatLng = LatLng(cached.latitude, cached.longitude);
      _locationMessage =
          "📍 Cached remote: Lat ${cached.latitude.toStringAsFixed(5)}, Lng ${cached.longitude.toStringAsFixed(5)}";
      _sharedRemoteUserId = cached.sharedUserId ?? _sharedRemoteUserId;
    });
  }

  Future<RemoteLocationData?> _loadRemoteLocation(String phoneNumber) async {
    final String trimmedNumber = phoneNumber.trim();
    if (trimmedNumber.isEmpty) {
      setState(() {
        _locationMessage = '⚠️ Enter a phone number to fetch remote location';
        _currentLatLng = null;
      });
      return null;
    }

    setState(() {
      _isLoadingRemoteLocation = true;
      _locationMessage = '📡 Loading remote location…';
    });

    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final RemoteLocationData? cached = await readPersistedRemoteLocation(prefs: prefs);
      final String? storedSharedId =
          prefs.getString(_prefsRemoteSharedUserIdKey) ?? _sharedRemoteUserId;

      final RemoteLocationData? remoteLocation = await fetchRemoteLocationForPhone(
        trimmedNumber,
        sharedUserId: storedSharedId,
      );

      if (!mounted) {
        return remoteLocation ?? cached;
      }

      if (remoteLocation == null) {
        if (cached != null) {
          setState(() {
            _isLoadingRemoteLocation = false;
            _currentLatLng = LatLng(cached.latitude, cached.longitude);
            _locationMessage =
                '⚠️ Unable to refresh remote location – showing cached data (last update ${_formatTimestamp(cached.lastUpdated)})';
            _sharedRemoteUserId =
                cached.sharedUserId ?? storedSharedId ?? _sharedRemoteUserId;
          });
          return cached;
        }

        setState(() {
          _isLoadingRemoteLocation = false;
          _currentLatLng = null;
          _locationMessage =
              '⚠️ No remote location available for $trimmedNumber';
        });
        return null;
      }

      await persistRemoteLocation(remoteLocation, prefs: prefs);

      final String message = remoteLocation.isStale
          ? '⚠️ Remote location may be stale (last update ${_formatTimestamp(remoteLocation.lastUpdated)})'
          : '📍 Remote: Lat ${remoteLocation.latitude.toStringAsFixed(5)}, Lng ${remoteLocation.longitude.toStringAsFixed(5)}';

      setState(() {
        _isLoadingRemoteLocation = false;
        _currentLatLng = LatLng(remoteLocation.latitude, remoteLocation.longitude);
        _locationMessage = message;
        _sharedRemoteUserId =
            remoteLocation.sharedUserId ?? storedSharedId ?? _sharedRemoteUserId;
      });

      if (remoteLocation.isStale) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '⚠️ Remote location may be stale. Last update ${_formatTimestamp(remoteLocation.lastUpdated)}',
            ),
          ),
        );
      }

      return remoteLocation;
    } catch (error) {
      debugPrint('Failed to load remote location for $trimmedNumber: $error');
      if (!mounted) {
        return null;
      }
      setState(() {
        _isLoadingRemoteLocation = false;
        _locationMessage = '⚠️ Failed to load remote location';
      });
      return null;
    }
  }

  // Pick time
  Future<void> _pickTime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked != null) {
      setState(() {
        _selectedTime = picked;
      });
    }
  }

  // Fetch location
  Future<void> _fetchLocation() async {
    setState(() {
      _isFetchingLocation = true;
      _locationMessage = "📡 Fetching location…";
    });

    String message = _locationMessage;
    LatLng? latLng = _currentLatLng;

    try {
      final position = await getCurrentLocation();
      unawaited(LocationSyncService.instance
          .start(userId: LocationSyncService.defaultUserId));
      message =
          "Lat: ${position.latitude.toStringAsFixed(5)}, Lng: ${position.longitude.toStringAsFixed(5)}";
      latLng = LatLng(position.latitude, position.longitude);
      unawaited(LocationSyncService.instance.pushPosition(position));
    } on PermissionDeniedException {
      message = "⚠️ Location permission denied";
      latLng = null;
    } on LocationServiceDisabledException {
      message = "⚠️ Enable location services to view map";
      latLng = null;
    } catch (e) {
      message = "⚠️ Failed to fetch location";
      latLng = null;
    }

    if (!mounted) return;

    setState(() {
      _isFetchingLocation = false;
      _locationMessage = message;
      _currentLatLng = latLng;
    });
  }

  // Schedule call
  Future<void> _scheduleCall() async {
    if (_phoneController.text.isEmpty || _selectedTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("⚠️ Enter number & select time")),
      );
      return;
    }

    final RemoteLocationData? remoteLocation =
        await _loadRemoteLocation(_phoneController.text);

    final now = DateTime.now();
    final scheduleTime = DateTime(
      now.year,
      now.month,
      now.day,
      _selectedTime!.hour,
      _selectedTime!.minute,
    );

    final duration = scheduleTime.difference(now);
    final delay =
        duration.isNegative ? duration + const Duration(days: 1) : duration;

    final Map<String, dynamic> alarmParams = {
      'phoneNumber': _phoneController.text,
    };

    if (remoteLocation != null) {
      alarmParams['remoteLat'] = remoteLocation.latitude;
      alarmParams['remoteLng'] = remoteLocation.longitude;
      if (remoteLocation.sharedUserId != null &&
          remoteLocation.sharedUserId!.isNotEmpty) {
        alarmParams['sharedUserId'] = remoteLocation.sharedUserId;
      }
    } else if (_sharedRemoteUserId != null &&
        _sharedRemoteUserId!.isNotEmpty) {
      alarmParams['sharedUserId'] = _sharedRemoteUserId;
    }

    final alarmId = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await AndroidAlarmManager.oneShot(
      delay,
      alarmId,
      _triggerCall,
      params: alarmParams,
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            "✅ Call scheduled at ${_selectedTime!.format(context)} ($_locationMessage)"),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("📞 Call Reminder + Location")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: "Phone Number",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _selectedTime == null
                        ? "No time selected"
                        : "Selected: ${_selectedTime!.format(context)}",
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _pickTime,
                  child: const Text("Pick Time"),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _isFetchingLocation ? null : _fetchLocation,
              icon: _isFetchingLocation
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.location_on),
              label: Text(
                _isFetchingLocation ? "Fetching…" : "Fetch My Location",
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _locationMessage,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 20),
            SizedBox(height: 220, child: _buildMapPreview()),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: (_isFetchingLocation || _isLoadingRemoteLocation)
                  ? null
                  : _scheduleCall,
              icon: const Icon(Icons.schedule),
              label: const Text("Schedule Call"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapPreview() {
    if (_currentLatLng == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.blueGrey.withValues(alpha: 0.08),
        ),
        child: const Center(
          child: Text(
            "Fetch your location to preview it on the map",
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: FlutterMap(
        options: MapOptions(
          initialCenter: _currentLatLng!,
          initialZoom: 15,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.girlfriend_call_app',
          ),
          MarkerLayer(markers: [
            Marker(
              point: _currentLatLng!,
              width: 40,
              height: 40,
              child: const Icon(
                Icons.location_on,
                color: Colors.red,
                size: 36,
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
