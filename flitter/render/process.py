"""
Multi-processing for rendering
"""

# pylama:ignore=R0903,R1732,R0913

import asyncio
import logging
from multiprocessing import Process, Queue
import os
import sys
import time


Log = logging.getLogger(__name__)


class Proxy:
    def __init__(self, cls, **kwargs):
        self.queue = Queue(1)
        self.process = Process(target=Proxy.run, args=(cls, kwargs, self.queue, logging.getLogger().level))
        self.process.start()

    async def update(self, *args, **kwargs):
        await asyncio.to_thread(self.queue.put, ('update', args, kwargs))

    def purge(self):
        self.connection.send(('purge', (), {}))

    def destroy(self):
        self.queue.close()
        self.queue.join_thread()
        self.process.terminate()
        self.process.join()
        self.process.close()
        self.queue = self.process = None

    @staticmethod
    def run(cls, kwargs, queue, log_level):
        logging.basicConfig(level=log_level, stream=sys.stderr)
        Log.info("Started %s process %d", cls.__name__, os.getpid())
        try:
            asyncio.run(Proxy.loop(queue, cls(**kwargs)))
        except Exception:
            Log.exception("Unhandled exception in %s process %d", cls.__name__, os.getpid())
        finally:
            Log.info("Stopped %s process %d", cls.__name__, os.getpid())

    @staticmethod
    async def loop(queue, obj):
        nframes = render = 0
        stats_time = time.perf_counter()
        while True:
            method, args, kwargs = queue.get()
            if method == 'update':
                render -= time.perf_counter()
                await obj.update(*args, **kwargs)
                render += time.perf_counter()
            elif method == 'purge':
                obj.purge()
            nframes += 1
            if time.perf_counter() > stats_time + 5:
                Log.info("%s process %d /frame render %.1fms", obj.__class__.__name__, os.getpid(), 1000*render/nframes)
                nframes = render = 0
                stats_time += 5
