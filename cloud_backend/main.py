import asyncio
import os
import joblib
import pandas as pd
import numpy as np
import datetime
from contextlib import asynccontextmanager

from fastapi import FastAPI, Depends, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy.sql import func
from sqlalchemy import cast
from geoalchemy2 import Geometry, Geography
from geoalchemy2.elements import WKTElement
from geoalchemy2.functions import ST_DWithin, ST_MakePoint, ST_SetSRID, ST_Distance, ST_Azimuth, ST_X, ST_Y
from sklearn.cluster import DBSCAN
from collections import defaultdict

from database import engine, Base, get_db, async_session
from models import SpatialJerkRegistry, Hazards

# Global variable for ML model
severity_model = None
background_task = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global severity_model, background_task
    
    # Initialize database tables (for prototype only, in prod use alembic)
    async with engine.begin() as conn:
        # Create extension if not exists requires superuser, we assume postgis is enabled
        from sqlalchemy import text
        await conn.execute(text("CREATE EXTENSION IF NOT EXISTS postgis;"))
        await conn.run_sync(Base.metadata.create_all)
        
    # Load ML Model
    model_path = os.path.join(os.path.dirname(__file__), 'severity_model.pkl')
    if os.path.exists(model_path):
        severity_model = joblib.load(model_path)
        print("Loaded ML model successfully.")
    else:
        print("Warning: severity_model.pkl not found. Run train_dummy.py first.")
    
    # Start background task
    background_task = asyncio.create_task(clustering_job())
    
    yield
    
    # Cleanup
    if background_task:
        background_task.cancel()

app = FastAPI(lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
async def root():
    return {"status": "success", "message": "Antigravity Cloud Backend is running. Visit /docs for API documentation."}

class TelemetryPayload(BaseModel):
    device_id: str
    lat: float
    lng: float
    peak_jerk: float
    dsr: float
    r_gyro: float
    vehicle_model: str = "Unknown"
    tyre_size: str = "Unknown"

class HazardUpdate(BaseModel):
    id: int
    status: str = None
    type: str = None

async def clustering_job():
    """Background task to periodically cluster telemetry and update hazards."""
    while True:
        try:
            # Run every 60 seconds for the prototype
            await asyncio.sleep(60)
            
            async with async_session() as db:
                now = datetime.datetime.now(datetime.timezone.utc)
                one_hour_ago = now - datetime.timedelta(hours=1)
                
                # Fetch recent telemetry points
                result = await db.execute(
                    select(
                        SpatialJerkRegistry.id,
                        SpatialJerkRegistry.device_id,
                        SpatialJerkRegistry.severity,
                        func.ST_X(SpatialJerkRegistry.geom).label('lon'),
                        func.ST_Y(SpatialJerkRegistry.geom).label('lat'),
                        SpatialJerkRegistry.timestamp
                    ).filter(SpatialJerkRegistry.timestamp >= one_hour_ago)
                )
                rows = result.fetchall()
                
                if not rows:
                    continue
                    
                coords = np.array([[np.radians(row.lat), np.radians(row.lon)] for row in rows])
                eps_rad = 8.0 / 6371000.0  # 8 meters in radians
                
                dbscan = DBSCAN(eps=eps_rad, min_samples=1, metric='haversine')
                labels = dbscan.fit_predict(coords)
                
                clusters = defaultdict(list)
                for label, row in zip(labels, rows):
                    if label != -1:
                        clusters[label].append(row)
                
                for cluster_id, pts in clusters.items():
                    distinct_devices = set(p.device_id for p in pts)
                    cumulative_severity = sum(p.severity for p in pts)
                    
                    avg_lon = np.mean([p.lon for p in pts])
                    avg_lat = np.mean([p.lat for p in pts])
                    
                    # Create a Point representation for the centroid
                    centroid = func.ST_SetSRID(func.ST_MakePoint(avg_lon, avg_lat), 4326)
                    
                    # Find nearest unrepaired hazard within 8m
                    hazard_res = await db.execute(
                        select(Hazards).filter(
                            Hazards.status == 'unrepaired',
                            func.ST_DWithin(
                                cast(Hazards.geom, Geography),
                                cast(centroid, Geography),
                                8.0
                            )
                        ).order_by(
                            func.ST_Distance(
                                cast(Hazards.geom, Geography),
                                cast(centroid, Geography)
                            )
                        ).limit(1)
                    )
                    hazard = hazard_res.scalar_one_or_none()
                    
                    if hazard:
                        if len(distinct_devices) > 1:
                            hazard.size = 'big_pothole' if cumulative_severity >= 6.5 else 'small_pothole'
                        else:
                            # If after time window only 1 distinct device hit this
                            hazard.status = 'false_alarm'
                
                await db.commit()
                
        except asyncio.CancelledError:
            break
        except Exception as e:
            print(f"Error in background clustering job: {e}")


@app.post("/api/telemetry")
async def ingest_telemetry(payload: TelemetryPayload, db: AsyncSession = Depends(get_db)):
    if not severity_model:
        raise HTTPException(status_code=503, detail="ML model not loaded")
        
    # Predict severity
    features = pd.DataFrame([{
        'PeakJerk': payload.peak_jerk,
        'DSR': payload.dsr,
        'R_gyro': payload.r_gyro
    }])
    pred_severity = severity_model.predict(features)[0]
    # Ensure it's bound between 1.0 and 10.0
    pred_severity = max(1.0, min(10.0, float(pred_severity)))
    
    new_point = f"SRID=4326;POINT({payload.lng} {payload.lat})"
    
    # Insert telemetry
    jerk_record = SpatialJerkRegistry(
        device_id=payload.device_id,
        geom=new_point,
        peak_jerk=payload.peak_jerk,
        dsr=payload.dsr,
        r_gyro=payload.r_gyro,
        severity=pred_severity,
        vehicle_model=payload.vehicle_model,
        tyre_size=payload.tyre_size
    )
    db.add(jerk_record)
    
    # Check "Pothole by Default" rule
    new_geom = func.ST_SetSRID(func.ST_MakePoint(payload.lng, payload.lat), 4326)
    
    # Look for existing hazards within 8m
    existing_hazard = await db.execute(
        select(Hazards).filter(
            func.ST_DWithin(
                cast(Hazards.geom, Geography),
                cast(new_geom, Geography),
                8.0
            )
        ).limit(1)
    )
    
    if not existing_hazard.scalar_one_or_none():
        new_hazard = Hazards(
            type='pothole',
            status='unrepaired',
            geom=new_point,
            size='unknown'
        )
        db.add(new_hazard)
        
    await db.commit()
    
    return {"status": "success", "predicted_severity": pred_severity}


@app.get("/api/radar")
async def get_radar(
    lat: float, 
    lng: float, 
    heading: float, 
    radius: float = Query(50.0, description="Search radius in meters"),
    db: AsyncSession = Depends(get_db)
):
    if radius not in [50.0, 90.0]:
        # Loosening strict requirement slightly for flexibility, but defaulting to spec
        pass 
        
    user_point = func.ST_SetSRID(func.ST_MakePoint(lng, lat), 4326)
    
    # Calculate azimuth in degrees
    # ST_Azimuth returns azimuth in radians from north, we convert to degrees
    azimuth_deg = func.degrees(func.ST_Azimuth(user_point, Hazards.geom))
    
    # 45-degree cone forward, wrap-around logic
    # difference = 180 - abs(abs(azimuth - heading) - 180)
    angle_diff = 180.0 - func.abs(func.abs(azimuth_deg - heading) - 180.0)
    
    result = await db.execute(
        select(Hazards).filter(
            Hazards.status == 'unrepaired',
            func.ST_DWithin(
                cast(Hazards.geom, Geography),
                cast(user_point, Geography),
                radius
            ),
            angle_diff <= 45.0
        )
    )
    
    hazards_data = []
    for h in result.scalars():
        # Get lat/lng to return to client
        # In SQLAlchemy 2.0 with async we can't lazy load geom attributes directly easily, 
        # but we can fetch them via explicit query if needed, 
        # or we could have requested ST_X and ST_Y in the query.
        pass
        
    # Let's adjust query to fetch coordinates directly for easy JSON serialization
    query = select(
        Hazards.id,
        Hazards.type,
        Hazards.status,
        Hazards.size,
        func.ST_X(Hazards.geom).label('lng'),
        func.ST_Y(Hazards.geom).label('lat')
    ).filter(
        Hazards.status == 'unrepaired',
        func.ST_DWithin(
            cast(Hazards.geom, Geography),
            cast(user_point, Geography),
            radius
        ),
        angle_diff <= 45.0
    )
    
    result = await db.execute(query)
    
    return [
        {
            "id": row.id,
            "type": row.type,
            "status": row.status,
            "size": row.size,
            "lat": row.lat,
            "lng": row.lng
        }
        for row in result.fetchall()
    ]


@app.get("/api/admin/hazards")
async def admin_get_hazards(db: AsyncSession = Depends(get_db)):
    query = select(
        Hazards.id,
        Hazards.type,
        Hazards.status,
        Hazards.size,
        func.ST_X(Hazards.geom).label('lng'),
        func.ST_Y(Hazards.geom).label('lat'),
        func.ST_AsText(Hazards.geom).label('geom_text')
    )
    result = await db.execute(query)
    hazards_rows = result.fetchall()
    
    response = []
    for row in hazards_rows:
        jerk_query = select(
            SpatialJerkRegistry.vehicle_model,
            SpatialJerkRegistry.tyre_size,
            SpatialJerkRegistry.severity
        ).filter(
            func.ST_DWithin(
                cast(SpatialJerkRegistry.geom, Geography),
                cast(func.ST_GeomFromText(row.geom_text, 4326), Geography),
                8.0
            )
        )
        jerk_res = await db.execute(jerk_query)
        jerks = [
            {"model": j.vehicle_model, "tyre": j.tyre_size, "severity": j.severity} 
            for j in jerk_res.fetchall()
        ]
        
        response.append({
            "id": row.id,
            "type": row.type,
            "status": row.status,
            "size": row.size,
            "lat": row.lat,
            "lng": row.lng,
            "jerks": jerks,
            "ai_severity_score": 8.0 if row.size == 'big_pothole' else (4.0 if row.size == 'small_pothole' else 1.0),
            "distinct_vehicle_hits": max(len(set(j["model"] for j in jerks if j["model"])), 1)
        })
        
    return response


@app.patch("/api/admin/update")
async def admin_update_hazard(payload: HazardUpdate, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Hazards).filter(Hazards.id == payload.id))
    hazard = result.scalar_one_or_none()
    if not hazard:
        raise HTTPException(status_code=404, detail="Hazard not found")
    
    if payload.status:
        hazard.status = payload.status
    if payload.type:
        hazard.type = payload.type
        
    await db.commit()
    return {"status": "success"}

@app.get("/api/admin/metrics")
async def admin_get_metrics(db: AsyncSession = Depends(get_db)):
    # Use native database time to avoid UTC timezone offset mismatches. Window is 1 minute for faster expiration.
    query = select(func.count(func.distinct(SpatialJerkRegistry.device_id))).filter(
        SpatialJerkRegistry.timestamp >= (func.now() - datetime.timedelta(minutes=1))
    )
    result = await db.execute(query)
    active_users = result.scalar() or 0
    
    return {"active_users": active_users}

