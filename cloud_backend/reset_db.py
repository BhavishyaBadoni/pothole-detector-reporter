import asyncio
from database import engine, Base
import models

async def drop_all():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)

asyncio.run(drop_all())
