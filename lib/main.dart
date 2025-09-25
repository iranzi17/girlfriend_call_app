import 'package:flutter/material.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AndroidAlarmManager.initialize();
  await requestPermissions();
  runApp(const MyApp());
}

// Request permissions
Future<void> requestPermissions() async {
  await Permission.phone.request();
  await Permission.location.request();
}

// Background call
Future<void> backgroundCall(String phoneNumber) async {
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

  if (!permissionStatus.isGranted) {
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
      message =
          "Lat: ${position.latitude.toStringAsFixed(5)}, Lng: ${position.longitude.toStringAsFixed(5)}";
      latLng = LatLng(position.latitude, position.longitude);
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

    await AndroidAlarmManager.oneShot(
      delay,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      () => backgroundCall(_phoneController.text),
      wakeup: true,
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
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _selectedTime == null
                      ? "No time selected"
                      : "Selected: ${_selectedTime!.format(context)}",
                ),
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
            Text(_locationMessage,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 20),
            SizedBox(height: 220, child: _buildMapPreview()),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _scheduleCall,
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
          color: Colors.blueGrey.withOpacity(0.08),
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
