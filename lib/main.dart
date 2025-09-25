import 'package:flutter/material.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
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
Future<String> getCurrentLocation() async {
  if (await Permission.location.request().isGranted) {
    Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
    return "Lat: ${pos.latitude}, Lng: ${pos.longitude}";
  } else {
    return "⚠️ Location permission denied";
  }
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
  String _location = "📍 Location not fetched";

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
    final loc = await getCurrentLocation();
    setState(() {
      _location = loc;
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
            "✅ Call scheduled at ${_selectedTime!.format(context)} ($_location)"),
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
              onPressed: _fetchLocation,
              icon: const Icon(Icons.location_on),
              label: const Text("Fetch My Location"),
            ),
            const SizedBox(height: 10),
            Text(_location,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
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
}
