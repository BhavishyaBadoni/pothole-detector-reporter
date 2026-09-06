import 'dart:isolate';
import 'dart:math';

class PhysicsMessage {
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;
  final double speed;
  final double lat;
  final double lng;
  final String deviceId;

  PhysicsMessage({
    required this.ax, required this.ay, required this.az,
    required this.gx, required this.gy, required this.gz,
    required this.speed, required this.lat, required this.lng,
    required this.deviceId,
  });
}

class TelemetryEvent {
  final String deviceId;
  final double lat;
  final double lng;
  final double peakJerk;
  final double dsr;
  final double rGyro;

  TelemetryEvent(this.deviceId, this.lat, this.lng, this.peakJerk, this.dsr, this.rGyro);
}

void physicsIsolateMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  // Filter state
  double gEstX = 0, gEstY = 0, gEstZ = 9.81;
  double prevVertAcc = 0;
  
  // Baseline variance calculation variables
  List<double> recentVertAccs = [];
  double baselineVariance = 0.5; // initial guess
  
  // Window logic
  bool isWindowLocked = false;
  int windowCounter = 0;
  List<double> windowJerks = [];
  List<double> windowGyrosX = [];
  List<double> windowGyrosY = [];
  List<double> windowGyrosZ = [];

  // Capture location and device info at trigger time
  double trigLat = 0, trigLng = 0;
  String trigDeviceId = '';

  receivePort.listen((message) {
    if (message is PhysicsMessage) {
      // EMA Filter for gravity
      gEstX = 0.98 * gEstX + 0.02 * message.ax;
      gEstY = 0.98 * gEstY + 0.02 * message.ay;
      gEstZ = 0.98 * gEstZ + 0.02 * message.az;

      // Gravity vector magnitude
      double gMag = sqrt(gEstX * gEstX + gEstY * gEstY + gEstZ * gEstZ);
      if (gMag == 0) gMag = 1;

      // Unit gravity vector
      double ux = gEstX / gMag;
      double uy = gEstY / gMag;
      double uz = gEstZ / gMag;

      // Project raw acceleration onto gravity vector
      double projAcc = message.ax * ux + message.ay * uy + message.az * uz;
      
      // True vertical acceleration (subtract 1g)
      double vertAcc = projAcc - 9.81;
      
      // Vertical jerk (rate of change of vertical acc at 50Hz, so multiply by 50)
      double jerk = (vertAcc - prevVertAcc) * 50.0;
      prevVertAcc = vertAcc;

      // Update baseline variance (rolling window of last 50 samples)
      recentVertAccs.add(vertAcc);
      if (recentVertAccs.length > 50) {
        recentVertAccs.removeAt(0);
        double mean = recentVertAccs.reduce((a, b) => a + b) / 50;
        baselineVariance = recentVertAccs.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b) / 50;
      }

      if (!isWindowLocked) {
        // Dynamic threshold
        double speedFactor = pow(message.speed / 36.0, 0.85).toDouble();
        double tJerk = 1.0 * (18.0 + 3.5 * baselineVariance * speedFactor);
        
        if (jerk.abs() > tJerk) {
          // Trigger! Lock window
          isWindowLocked = true;
          windowCounter = 0;
          windowJerks.clear();
          windowGyrosX.clear();
          windowGyrosY.clear();
          windowGyrosZ.clear();
          
          trigLat = message.lat;
          trigLng = message.lng;
          trigDeviceId = message.deviceId;
        }
      }

      if (isWindowLocked) {
        windowJerks.add(jerk);
        windowGyrosX.add(message.gx);
        windowGyrosY.add(message.gy);
        windowGyrosZ.add(message.gz);
        windowCounter++;
        
        if (windowCounter >= 75) {
          // Extract 3D features
          double peakJerk = windowJerks.reduce((a, b) => a.abs() > b.abs() ? a : b);
          
          double maxJerk = windowJerks.reduce(max);
          double minJerk = windowJerks.reduce(min);
          
          // Dip-to-Spike Ratio (DSR)
          double dsr = 1.0;
          if (maxJerk > 0 && minJerk < 0) {
             dsr = (minJerk.abs() / maxJerk.abs());
          }

          // Rotational Variance Ratio
          double varGx = variance(windowGyrosX);
          double varGy = variance(windowGyrosY);
          double varGz = variance(windowGyrosZ);
          double rGyro = (varGx + varGy) / (varGz + 0.001);

          // Send event to main thread
          mainSendPort.send(TelemetryEvent(
            trigDeviceId, trigLat, trigLng, peakJerk, dsr, rGyro
          ));

          // Unlock window
          isWindowLocked = false;
        }
      }
    }
  });
}

double variance(List<double> values) {
  if (values.isEmpty) return 0;
  double mean = values.reduce((a, b) => a + b) / values.length;
  double sumSq = values.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b).toDouble();
  return sumSq / values.length;
}
