import 'dart:async';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vibration/vibration.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../isolate/physics_isolate.dart';
import '../services/api_service.dart';
import '../services/database_service.dart';
import '../models/api_models.dart';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import '../main.dart';

class RadarUI extends StatefulWidget {
  const RadarUI({Key? key}) : super(key: key);

  @override
  _RadarUIState createState() => _RadarUIState();
}

enum AppState { initial, calibrating, vehicleSetup, ready, active }

class _RadarUIState extends State<RadarUI> {
  AppState appState = AppState.initial;
  bool isRaining = false;
  double searchRadius = 50.0;
  
  String? vehicleModel = 'Sedan';
  String? tyreSize = '15 inch';
  final List<String> vehicleModels = ['Sedan', 'SUV', 'Hatchback', 'Truck', 'Motorcycle'];
  final List<String> tyreSizes = ['15 inch', '16 inch', '17 inch', '18+ inch'];
  
  // Location and Sensors
  Position? currentPosition;
  StreamSubscription<Position>? positionStream;
  StreamSubscription<UserAccelerometerEvent>? accelStream;
  StreamSubscription<GyroscopeEvent>? gyroStream;
  
  Timer? radarTimer;
  Timer? uiUpdateTimer;
  
  // Isolate
  Isolate? physicsIsolate;
  SendPort? isolateSendPort;
  ReceivePort? mainReceivePort;

  double ax = 0, ay = 0, az = 0;
  double gx = 0, gy = 0, gz = 0;

  // Calibration state
  bool isStable = false;
  double calibrationProgress = 0.0;
  Timer? calibrationTimer;
  StreamSubscription<GyroscopeEvent>? calibGyroStream;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _checkCalibrationStatus();
  }

  Future<void> _checkCalibrationStatus() async {
    final prefs = await SharedPreferences.getInstance();
    bool isCalibrated = prefs.getBool('isCalibrated') ?? false;
    if (isCalibrated) {
      if (mounted) {
        setState(() { appState = AppState.vehicleSetup; });
      }
    }
  }

  Future<void> _requestPermissions() async {
    // Notification Permissions
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }

    // Location Permissions
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
  }

  Future<void> _calibrateSensors() async {
    setState(() { 
      appState = AppState.calibrating; 
      calibrationProgress = 0.0;
      isStable = false;
    });

    int consecutiveStableMs = 0;
    const int targetStableMs = 3000;
    const int updateIntervalMs = 100;
    
    calibGyroStream = gyroscopeEventStream(samplingPeriod: const Duration(milliseconds: 100)).listen((event) {
      if (!mounted || appState != AppState.calibrating) return;
      
      // Check if phone is stationary (gyro values near 0)
      bool currentStable = (event.x.abs() < 0.1 && event.y.abs() < 0.1 && event.z.abs() < 0.1);
      
      if (currentStable) {
        consecutiveStableMs += updateIntervalMs;
      } else {
        consecutiveStableMs = 0; // Reset if shaken
      }

      setState(() {
        isStable = currentStable;
        calibrationProgress = (consecutiveStableMs / targetStableMs).clamp(0.0, 1.0);
      });

      if (consecutiveStableMs >= targetStableMs) {
        _finishCalibration();
      }
    });
  }

  Future<void> _finishCalibration() async {
    calibGyroStream?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isCalibrated', true);
    if (mounted) {
      setState(() { appState = AppState.vehicleSetup; });
    }
  }

  Future<void> _startJourney() async {
    if (appState == AppState.active) return;
    
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('GPS is disabled. Turn on Location Services.');
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception('Location permission denied.');
        }
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception('Location permission permanently denied.');
      }

      // Get initial position
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 10),
      );
      setState(() { currentPosition = pos; });

      // Use manually selected weather
      searchRadius = isRaining ? 90.0 : 50.0;
      
      // Spawn Isolate
      mainReceivePort = ReceivePort();
      physicsIsolate = await Isolate.spawn(physicsIsolateMain, mainReceivePort!.sendPort);
      
      mainReceivePort!.listen((message) {
        if (message is SendPort) {
          isolateSendPort = message;
          _startSensors();
        } else if (message is TelemetryEvent) {
          // Trigger telemetry POST
          _handleTelemetry(message);
        }
      });

      // Start Radar Polling
      radarTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
        _pollRadar();
      });

      // Start UI update loop (2Hz) to prevent overloading the screen with 50Hz data
      uiUpdateTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        if (mounted) setState(() {});
      });

      setState(() {
        appState = AppState.active;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed: $e', style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ));
      }
    }
  }

  void _startSensors() {
    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0, // Get updates as frequently as possible, regardless of distance moved
      )
    ).listen((Position position) {
      currentPosition = position;
    });

    accelStream = userAccelerometerEventStream(samplingPeriod: const Duration(milliseconds: 20)).listen((event) {
      ax = event.x; ay = event.y; az = event.z;
      _sendToIsolate();
    });

    gyroStream = gyroscopeEventStream(samplingPeriod: const Duration(milliseconds: 20)).listen((event) {
      gx = event.x; gy = event.y; gz = event.z;
    });
  }

  void _sendToIsolate() {
    if (isolateSendPort != null && currentPosition != null) {
      isolateSendPort!.send(PhysicsMessage(
        ax: ax, ay: ay, az: az,
        gx: gx, gy: gy, gz: gz,
        speed: currentPosition!.speed * 3.6, // m/s to km/h
        lat: currentPosition!.latitude,
        lng: currentPosition!.longitude,
        deviceId: 'device_123', // Static for this build
      ));
    }
  }

  Future<void> _handleTelemetry(TelemetryEvent event) async {
    final payload = TelemetryPayload(
      deviceId: event.deviceId,
      lat: event.lat,
      lng: event.lng,
      peakJerk: event.peakJerk,
      dsr: event.dsr,
      rGyro: event.rGyro,
      vehicleModel: vehicleModel,
      tyreSize: tyreSize,
    );
    await ApiService.postTelemetry(payload);
  }

  Future<void> _pollRadar() async {
    if (currentPosition == null) return;
    
    List<Hazard> hazards = await ApiService.getRadar(
      currentPosition!.latitude,
      currentPosition!.longitude,
      currentPosition!.heading,
      searchRadius
    );

    for (var hazard in hazards) {
      bool canAlert = await DatabaseService.instance.canAlert(hazard.id, isRaining);
      if (canAlert) {
        _triggerTieredAlert(hazard);
      }
    }
  }

  Future<void> _showNotification(String title, String body, {bool critical = false}) async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'hazard_alerts',
      'Hazard Alerts',
      channelDescription: 'Alerts for upcoming road hazards',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'Hazard Alert',
      enableVibration: true,
      color: Colors.red,
    );
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    await flutterLocalNotificationsPlugin.show(
      0,
      title,
      body,
      platformChannelSpecifics,
    );
  }

  Future<void> _triggerTieredAlert(Hazard hazard) async {
    bool hasVibrator = await Vibration.hasVibrator() ?? false;
    
    if (hazard.size == 'small_pothole') {
      if (hasVibrator) Vibration.vibrate(pattern: [0, 100, 100, 100]);
      _showNotification('Hazard Detected', 'Small pothole ahead.');
    } else if (hazard.type == 'speed_breaker') {
      if (hasVibrator) Vibration.vibrate(pattern: [0, 100, 100, 100, 100, 100]);
      _showNotification('Speed Breaker Ahead', 'Slow down for upcoming speed breaker.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Row(
            children: [
              Icon(Icons.warning, color: Colors.black),
              SizedBox(width: 10),
              Text('Speed Breaker Ahead!', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ],
          ),
          backgroundColor: Colors.amberAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 3),
        ));
      }
    } else if (hazard.size == 'big_pothole') {
      if (hasVibrator) Vibration.vibrate(duration: 5000);
      _showNotification('CRITICAL HAZARD', 'Big pothole ahead! Brace for impact.', critical: true);
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return AlertDialog(
              backgroundColor: Colors.red[900],
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Row(
                children: [
                  Icon(Icons.dangerous, color: Colors.white, size: 32),
                  SizedBox(width: 10),
                  Text('DANGER', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ),
              content: const Text('BIG POTHOLE AHEAD!', style: TextStyle(color: Colors.white, fontSize: 18)),
              actions: [
                TextButton(
                  child: const Text('DISMISS', style: TextStyle(color: Colors.white70, fontSize: 16)),
                  onPressed: () {
                    Vibration.cancel();
                    Navigator.of(context).pop();
                  },
                )
              ],
            );
          }
        );
      }
    }
  }

  void _endJourney() {
    positionStream?.cancel();
    accelStream?.cancel();
    gyroStream?.cancel();
    calibGyroStream?.cancel();
    radarTimer?.cancel();
    uiUpdateTimer?.cancel();
    physicsIsolate?.kill(priority: Isolate.immediate);
    mainReceivePort?.close();
    
    setState(() {
      appState = AppState.initial;
    });
  }

  @override
  void dispose() {
    _endJourney();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edge Physics Radar', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: appState == AppState.active 
                ? _buildActiveDashboard()
                : Center(
                    child: appState == AppState.initial
                      ? _buildInitialState()
                      : appState == AppState.calibrating
                        ? _buildCalibratingState()
                        : appState == AppState.vehicleSetup
                          ? _buildVehicleSetup()
                          : _buildReadyState(),
                  ),
            ),
            // Journey Controls
            _buildBottomControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveDashboard() {
    double speed = (currentPosition?.speed ?? 0) * 3.6;
    if (speed < 3.0) speed = 0.0; // Clamp GPS drift when stationary
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
      children: [
        // Modern Speedometer 
        Center(
          child: Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.tealAccent.withOpacity(0.3), width: 8),
              gradient: RadialGradient(
                colors: [Colors.tealAccent.withOpacity(0.1), Colors.transparent],
                stops: const [0.5, 1.0],
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(speed.toStringAsFixed(0), style: const TextStyle(fontSize: 64, fontWeight: FontWeight.bold, color: Colors.white)),
                const Text('km/h', style: TextStyle(fontSize: 18, color: Colors.grey)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 30),
        const Text('TELEMETRY STATUS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 2.0)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _buildMiniStat('LAT', currentPosition?.latitude.toStringAsFixed(4) ?? "--")),
            const SizedBox(width: 12),
            Expanded(child: _buildMiniStat('LNG', currentPosition?.longitude.toStringAsFixed(4) ?? "--")),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildMiniStat('ACCEL (Z)', '${az.toStringAsFixed(1)} m/s²')),
            const SizedBox(width: 12),
            Expanded(child: _buildMiniStat('GYRO (X)', '${gx.toStringAsFixed(1)} r/s')),
          ],
        ),
        const SizedBox(height: 20),
        // Temporary manual jerk button
        ElevatedButton.icon(
          icon: const Icon(Icons.warning_amber_rounded),
          label: const Text("TEST MANUAL JERK", style: TextStyle(fontWeight: FontWeight.bold)),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orangeAccent,
            foregroundColor: Colors.black,
            minimumSize: const Size(double.infinity, 50),
          ),
          onPressed: () {
            if (currentPosition != null) {
              final ev = TelemetryEvent(
                'device_123',
                currentPosition!.latitude,
                currentPosition!.longitude,
                45.0, // Simulate a very large bump
                2.5,
                7.0,
              );
              _handleTelemetry(ev);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Test bump sent to backend!'), 
                  backgroundColor: Colors.green,
                  duration: Duration(seconds: 2),
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Waiting for GPS...')),
              );
            }
          },
        ),
      ],
    );
  }

  Widget _buildMiniStat(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.tealAccent, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildInitialState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.radar, size: 80, color: Colors.tealAccent.withOpacity(0.8)),
        const SizedBox(height: 20),
        const Text('Ready to connect.', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 10),
        const Text('Ensure phone is mounted securely to the dashboard.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Colors.grey)),
      ],
    );
  }

  Widget _buildCalibratingState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('Calibrating Sensors', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 10),
        const Text('Please do not move the vehicle.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 16)),
        const SizedBox(height: 50),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isStable ? Colors.green.withOpacity(0.1) : Colors.orange.withOpacity(0.1),
          ),
          child: Icon(
            isStable ? Icons.check_circle : Icons.warning_amber_rounded,
            size: 80,
            color: isStable ? Colors.greenAccent : Colors.orangeAccent,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          isStable ? 'Stable' : 'Detecting Movement...', 
          style: TextStyle(color: isStable ? Colors.greenAccent : Colors.orangeAccent, fontSize: 20, fontWeight: FontWeight.bold)
        ),
        const SizedBox(height: 40),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 60.0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: calibrationProgress,
              minHeight: 12,
              backgroundColor: const Color(0xFF2C2C2C),
              valueColor: AlwaysStoppedAnimation<Color>(isStable ? Colors.greenAccent : Colors.orangeAccent),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('${(calibrationProgress * 100).toInt()}%', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18)),
      ],
    );
  }

  Widget _buildVehicleSetup() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 30.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.directions_car, size: 60, color: Colors.tealAccent),
          const SizedBox(height: 20),
          const Text('Vehicle Setup', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 8),
          const Text('Configure AI telemetry profile', style: TextStyle(color: Colors.grey, fontSize: 14)),
          const SizedBox(height: 40),
          _buildDropdown('Vehicle Model', vehicleModel, vehicleModels, (val) => setState(() => vehicleModel = val)),
          const SizedBox(height: 20),
          _buildDropdown('Tyre Size', tyreSize, tyreSizes, (val) => setState(() => tyreSize = val)),
          const SizedBox(height: 40),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.tealAccent,
              foregroundColor: Colors.black,
              minimumSize: const Size(double.infinity, 56),
              elevation: 4,
            ),
            onPressed: () => setState(() => appState = AppState.ready),
            child: const Text('CONFIRM PROFILE', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
          )
        ],
      ),
    );
  }

  Widget _buildDropdown(String label, String? value, List<String> items, Function(String?) onChanged) {
    return DropdownButtonFormField<String>(
      value: value,
      dropdownColor: const Color(0xFF2C2C2C),
      style: const TextStyle(color: Colors.white, fontSize: 16),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.grey),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.grey)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.tealAccent, width: 2)),
        filled: true,
        fillColor: const Color(0xFF1E1E1E),
      ),
      items: items.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
      onChanged: onChanged,
    );
  }

  Widget _buildReadyState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle_outline, size: 80, color: Colors.greenAccent),
        const SizedBox(height: 20),
        const Text('Profile Loaded.', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 10),
        const Text('Ready to begin telemetry logging.', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Colors.grey)),
      ],
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 30),
      decoration: const BoxDecoration(
        color: Color(0xFF1F1F1F),
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        boxShadow: [BoxShadow(color: Colors.black26, offset: Offset(0, -4), blurRadius: 10)],
      ),
      child: Column(
        children: [
          if (appState == AppState.ready || appState == AppState.active)
            Padding(
              padding: const EdgeInsets.only(bottom: 20.0, top: 10.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.wb_sunny, color: isRaining ? Colors.grey : Colors.orangeAccent, size: 20),
                  const SizedBox(width: 8),
                  Text('DRY', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: isRaining ? Colors.grey : Colors.white)),
                  const SizedBox(width: 10),
                  Switch(
                    value: isRaining,
                    activeColor: Colors.blueAccent,
                    onChanged: appState == AppState.active ? null : (val) {
                      setState(() { isRaining = val; });
                    },
                  ),
                  const SizedBox(width: 10),
                  Text('RAIN', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: isRaining ? Colors.white : Colors.grey)),
                  const SizedBox(width: 8),
                  Icon(Icons.water_drop, color: isRaining ? Colors.blueAccent : Colors.grey, size: 20),
                ],
              ),
            ),
          
          if (appState != AppState.vehicleSetup)
            SizedBox(
              width: double.infinity,
              height: 64,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: appState == AppState.active ? Colors.redAccent : (appState == AppState.ready ? Colors.greenAccent : Colors.tealAccent),
                  foregroundColor: appState == AppState.active ? Colors.white : Colors.black,
                  elevation: 8,
                ),
                onPressed: appState == AppState.calibrating 
                  ? null 
                  : (appState == AppState.initial 
                      ? _calibrateSensors 
                      : (appState == AppState.ready ? _startJourney : _endJourney)),
                child: Text(
                  appState == AppState.initial ? 'CALIBRATE SENSORS' 
                    : (appState == AppState.ready ? 'START JOURNEY' 
                      : (appState == AppState.active ? 'END JOURNEY' : 'CALIBRATING...')),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
