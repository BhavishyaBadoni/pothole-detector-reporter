import os
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import declarative_base, sessionmaker

# Database URL format: postgresql+asyncpg://user:password@host:port/dbname
DATABASE_URL = os.environ.get(
    "DATABASE_URL", 
    "postgresql+asyncpg://postgres:postgres@localhost:5432/postgres"
)

# Create the async engine
engine = create_async_engine(DATABASE_URL, echo=True)

# Create an async session maker
async_session = sessionmaker(
    engine, class_=AsyncSession, expire_on_commit=False
)

Base = declarative_base()

# Dependency to get the async session for FastAPI routes
async def get_db():
    async with async_session() as session:
        yield session
