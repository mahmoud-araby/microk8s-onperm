"""Schema bootstrap, runnable as the chart's migrations init container: `python -m app.migrate`."""

import asyncio

from app.config import get_settings
from app.db import create_engine, create_schema


async def main() -> None:
    engine = create_engine(get_settings())
    try:
        await create_schema(engine)
    finally:
        await engine.dispose()


if __name__ == "__main__":
    asyncio.run(main())
