import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/api_models.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';

class ApiService {
  // Use the PC's Wi-Fi IP since we are testing on a physical Android phone.
  static String get baseUrl {
    if (kIsWeb) return 'http://localhost:8080';
    if (Platform.isAndroid) return 'http://10.0.2.2:8080'; // 10.0.2.2 is localhost for Android Emulators
    return 'http://localhost:8080';
  }

  static Future<bool> postTelemetry(TelemetryPayload payload) async {
    try {
      final url = Uri.parse('$baseUrl/api/telemetry');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload.toJson()),
      );
      if (response.statusCode == 200) {
        return true;
      } else {
        print('Error posting telemetry: \${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('Exception posting telemetry: \$e');
      return false;
    }
  }

  static Future<List<Hazard>> getRadar(double lat, double lng, double heading, double radius) async {
    try {
      final url = Uri.parse('$baseUrl/api/radar?lat=\$lat&lng=\$lng&heading=\$heading&radius=\$radius');
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final List<dynamic> jsonList = jsonDecode(response.body);
        return jsonList.map((j) => Hazard.fromJson(j)).toList();
      } else {
        print('Error fetching radar: \${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('Exception fetching radar: \$e');
      return [];
    }
  }

  // Mocked weather API for now as no key was provided
  static Future<bool> isRaining(double lat, double lng) async {
    // In a real app we would call openweather API.
    // For demo purposes, we randomly simulate rain 30% of the time.
    await Future.delayed(const Duration(milliseconds: 500));
    final now = DateTime.now().minute;
    return now % 3 == 0; // Just a stub logic
  }
}
