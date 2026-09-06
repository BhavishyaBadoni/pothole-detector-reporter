import time
import random
import requests
import math

# Backend URL
API_URL = "http://localhost:8001/api/telemetry"

# Dehradun Center
CENTER_LAT = 30.3165
CENTER_LNG = 78.0322

# Let's define some "known" pothole locations around the center
# Offset is roughly 0.001 deg ~ 100 meters
RAW_HAZARDS = [
    {"lat": CENTER_LAT + 0.002, "lng": CENTER_LNG + 0.001, "type": "big_pothole"},
    {"lat": CENTER_LAT - 0.001, "lng": CENTER_LNG - 0.002, "type": "small_pothole"},
    {"lat": CENTER_LAT + 0.003, "lng": CENTER_LNG - 0.003, "type": "speed_breaker"},
    {"lat": CENTER_LAT - 0.002, "lng": CENTER_LNG + 0.004, "type": "big_pothole"},
    {"lat": CENTER_LAT, "lng": CENTER_LNG + 0.002, "type": "small_pothole"},
]

KNOWN_HAZARDS = []
print("Snapping hazards to exact roads using OSRM...")
for h in RAW_HAZARDS:
    try:
        url = f"http://router.project-osrm.org/nearest/v1/driving/{h['lng']},{h['lat']}"
        res = requests.get(url, timeout=5)
        if res.status_code == 200:
            coords = res.json()['waypoints'][0]['location']
            KNOWN_HAZARDS.append({
                "lat": coords[1],
                "lng": coords[0],
                "type": h["type"]
            })
            print(f"Snapped {h['type']} to road: {coords[1]:.5f}, {coords[0]:.5f}")
        else:
            KNOWN_HAZARDS.append(h)
    except Exception as e:
        KNOWN_HAZARDS.append(h)

VEHICLE_MODELS = ['Sedan', 'SUV', 'Hatchback', 'Truck', 'Motorcycle']
TYRE_SIZES = ['15 inch', '16 inch', '17 inch', '18+ inch']

def generate_telemetry(device_id, hazard):
    # Simulate some variance in GPS
    lat = hazard["lat"] + random.uniform(-0.00005, 0.00005)
    lng = hazard["lng"] + random.uniform(-0.00005, 0.00005)
    
    # Simulate physics based on hazard type
    if hazard["type"] == "big_pothole":
        peak_jerk = random.uniform(25.0, 45.0)
        dsr = random.uniform(1.5, 3.0)
        r_gyro = random.uniform(4.0, 8.0)
    elif hazard["type"] == "small_pothole":
        peak_jerk = random.uniform(15.0, 25.0)
        dsr = random.uniform(1.0, 1.5)
        r_gyro = random.uniform(1.0, 3.0)
    else: # speed_breaker
        peak_jerk = random.uniform(10.0, 20.0)
        dsr = random.uniform(0.5, 1.0)
        r_gyro = random.uniform(0.5, 1.5)

    return {
        "device_id": f"device_{device_id}",
        "lat": lat,
        "lng": lng,
        "peak_jerk": peak_jerk,
        "dsr": dsr,
        "r_gyro": r_gyro,
        "vehicle_model": random.choice(VEHICLE_MODELS),
        "tyre_size": random.choice(TYRE_SIZES)
    }

def main():
    print("Starting Traffic Simulator...")
    print(f"Target API: {API_URL}")
    print("Press Ctrl+C to stop.\n")
    
    try:
        while True:
            # Randomly pick 1 to 3 devices to be "active" this second
            num_devices = random.randint(1, 3)
            
            for _ in range(num_devices):
                device_id = random.randint(100, 105) # 5 distinct devices driving around
                hazard = random.choice(KNOWN_HAZARDS)
                
                payload = generate_telemetry(device_id, hazard)
                
                try:
                    response = requests.post(API_URL, json=payload)
                    if response.status_code == 200:
                        sev = response.json().get("predicted_severity", 0)
                        print(f"[Device {device_id}] Hit hazard! Predicted Severity: {sev:.2f} | Lat: {payload['lat']:.4f}")
                    else:
                        print(f"Failed to send telemetry: {response.status_code} - {response.text}")
                except Exception as e:
                    print(f"Connection error: {e}")
            
            # Wait 2 seconds before next batch
            time.sleep(2)
            
    except KeyboardInterrupt:
        print("\nTraffic Simulator stopped.")

if __name__ == "__main__":
    main()
