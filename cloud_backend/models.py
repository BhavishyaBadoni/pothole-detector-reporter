from sqlalchemy import Column, Integer, String, Float, DateTime
from sqlalchemy.sql import func
from geoalchemy2 import Geometry
from database import Base

class SpatialJerkRegistry(Base):
    __tablename__ = "spatial_jerk_registry"

    id = Column(Integer, primary_key=True, index=True)
    device_id = Column(String, index=True, nullable=False)
    timestamp = Column(DateTime(timezone=True), server_default=func.now())
    # SRID 4326 is standard WGS84 for lat/lon
    geom = Column(Geometry('POINT', srid=4326), nullable=False)
    peak_jerk = Column(Float, nullable=False)
    dsr = Column(Float, nullable=False)
    r_gyro = Column(Float, nullable=False)
    severity = Column(Float, nullable=False)
    vehicle_model = Column(String, nullable=True)
    tyre_size = Column(String, nullable=True)

class Hazards(Base):
    __tablename__ = "hazards"

    id = Column(Integer, primary_key=True, index=True)
    type = Column(String, default="pothole", nullable=False)
    # status can be: unrepaired, repaired, false_alarm
    status = Column(String, default="unrepaired", nullable=False)
    geom = Column(Geometry('POINT', srid=4326), nullable=False)
    # size can be: small_pothole, big_pothole, unknown
    size = Column(String, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
