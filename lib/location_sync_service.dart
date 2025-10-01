import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

/// A singleton service that keeps the user's location in sync with Firestore
/// and schedules periodic background updates so other devices know the last
/// reported position.
class LocationSyncService {
  LocationSyncService._internal();

  /// Default user id used for demo purposes. Replace with an authenticated id
  /// in production.
  static const String defaultUserId = 'demo-user';

  static const Duration _backgroundInterval = Duration(minutes: 15);
  static const Duration _retryInterval = Duration(minutes: 1);
  static const int _backgroundAlarmId = 424242;

  static final LocationSyncService instance = LocationSyncService._internal();

  static FirebaseFirestore? _firestoreInstance;

  static FirebaseFirestore get _firestore {
    final firestore = _firestoreInstance;
    if (firestore == null) {
      throw StateError('Firebase has not been initialized');
    }
    return firestore;
  }
  StreamSubscription<Position>? _positionSubscription;
  Timer? _retryTimer;
  Position? _pendingPosition;

  String? _userId;
  bool _isStarted = false;

  /// Starts listening to location updates if permission is granted and ensures
  /// that background syncing is scheduled.
  Future<void> start({required String userId}) async {
    _userId = userId;

    final locationStatus = await Permission.location.status;
    if (!locationStatus.isGranted) {
      _isStarted = false;
      return;
    }

    if (_isStarted) {
      return;
    }

    final initialized = await _ensureFirebaseInitialized();
    if (!initialized) {
      _isStarted = false;
      return;
    }

    _isStarted = true;
    await _ensureLocationStream();
    await syncCurrentLocation();
    await _scheduleBackgroundSync();
  }

  /// Forces an immediate location fetch and upload.
  Future<void> syncCurrentLocation() async {
    if (_userId == null) {
      return;
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      await _uploadPosition(position);
    } catch (error) {
      debugPrint('LocationSyncService: failed to fetch current position: '
          '$error');
    }
  }

  /// Pushes a position that was obtained elsewhere (e.g. via the UI) to
  /// Firestore.
  Future<void> pushPosition(Position position) async {
    if (_userId == null) {
      return;
    }
    await _uploadPosition(position);
  }

  Future<void> _ensureLocationStream() async {
    _positionSubscription ??=
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 50,
          ),
        ).listen(
          (position) {
            unawaited(_uploadPosition(position));
          },
          onError: (error) {
            debugPrint('LocationSyncService: position stream error: $error');
          },
        );
  }

  Future<void> _uploadPosition(Position position) async {
    final userId = _userId;
    if (userId == null) {
      return;
    }

    _pendingPosition = position;

    final payload = <String, dynamic>{
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    try {
      final initialized = await _ensureFirebaseInitialized();
      if (!initialized) {
        debugPrint(
            'LocationSyncService: skipping upload because Firebase failed to initialize');
        _scheduleRetry();
        return;
      }

      await _firestore
          .collection('users')
          .doc(userId)
          .set(payload, SetOptions(merge: true));
      if (identical(_pendingPosition, position)) {
        _pendingPosition = null;
      }
      _retryTimer?.cancel();
    } catch (error) {
      debugPrint('LocationSyncService: failed to upload position: $error');
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryInterval, () {
      final pending = _pendingPosition;
      if (pending != null) {
        unawaited(_uploadPosition(pending));
      }
    });
  }

  Future<void> _scheduleBackgroundSync() async {
    final userId = _userId;
    if (userId == null) {
      return;
    }

    final nextRun = DateTime.now().add(_backgroundInterval);
    await AndroidAlarmManager.oneShotAt(
      nextRun,
      _backgroundAlarmId,
      _backgroundCallback,
      params: {'userId': userId},
      allowWhileIdle: true,
      wakeup: true,
      rescheduleOnReboot: true,
    );
  }

  @pragma('vm:entry-point')
  static Future<void> _backgroundCallback(dynamic params) async {
    WidgetsFlutterBinding.ensureInitialized();
    final initialized = await _ensureFirebaseInitialized();
    if (!initialized) {
      debugPrint('LocationSyncService background: Firebase initialization failed');
      return;
    }

    final userId =
        params is Map<String, dynamic> ? params['userId'] as String? : null;
    if (userId == null) {
      debugPrint('LocationSyncService background: missing user id');
      return;
    }

    Position? position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
        ),
      );
    } catch (error) {
      debugPrint('LocationSyncService background: unable to get position: '
          '$error');
    }

    var success = false;
    if (position != null) {
      final payload = <String, dynamic>{
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      try {
        await _firestore
            .collection('users')
            .doc(userId)
            .set(payload, SetOptions(merge: true));
        success = true;
      } catch (error) {
        debugPrint('LocationSyncService background: upload failed: $error');
      }
    }

    final nextInterval = success ? _backgroundInterval : _retryInterval;
    final nextRun = DateTime.now().add(nextInterval);
    await AndroidAlarmManager.oneShotAt(
      nextRun,
      _backgroundAlarmId,
      _backgroundCallback,
      params: {'userId': userId},
      allowWhileIdle: true,
      wakeup: true,
      rescheduleOnReboot: true,
    );
  }

  static Future<bool> _ensureFirebaseInitialized() async {
    if (_firestoreInstance != null) {
      return true;
    }

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
    } catch (error) {
      debugPrint('LocationSyncService: Firebase initialization error: $error');
      return false;
    }

    try {
      _firestoreInstance = FirebaseFirestore.instance;
    } catch (error) {
      debugPrint('LocationSyncService: unable to obtain Firestore instance: $error');
      return false;
    }

    return true;
  }
}
