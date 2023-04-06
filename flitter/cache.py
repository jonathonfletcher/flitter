"""
General file cache
"""

from pathlib import Path
import time

from loguru import logger


class CachePath:
    def __init__(self, path):
        self._touched = time.monotonic()
        self._path = path
        self._cache = {}

    def cleanup(self):
        while self._cache:
            key, value = self._cache.popitem()
            match key:
                case 'video', _:
                    mtime, container, decoder, frames = value
                    if decoder is not None:
                        decoder.close()
                    if container is not None:
                        container.close()
                        logger.debug("Closing video file: {}", self._path)

    def read_text(self, encoding=None, errors=None):
        self._touched = time.monotonic()
        key = 'text', encoding, errors
        mtime = self._path.stat().st_mtime if self._path.exists() else None
        if key in self._cache:
            cache_mtime, text = self._cache[key]
            if mtime == cache_mtime:
                return text
        if mtime is None:
            logger.warning("File not found: {}", self._path)
            text = None
        else:
            try:
                text = self._path.read_text(encoding, errors)
            except Exception as exc:
                logger.opt(exception=exc).warning("Error reading text file: {}", self._path)
                text = None
            else:
                logger.debug("Read text file: {}", self._path)
        self._cache[key] = mtime, text
        return text

    def read_flitter_program(self, definitions=None):
        from .model import Vector, Context
        from .language.parser import parse, ParseError
        self._touched = time.monotonic()
        mtime = self._path.stat().st_mtime if self._path.exists() else None
        if 'flitter' in self._cache:
            cache_mtime, top = self._cache['flitter']
            if mtime == cache_mtime:
                return top
        else:
            top = None
        if mtime is None:
            logger.warning("Program file not found: {}", self._path)
            top = None
        else:
            try:
                start = time.perf_counter()
                source = self._path.read_text(encoding='utf8')
                initial_top = parse(source)
                mid = time.perf_counter()
                top = initial_top.simplify(variables=definitions)
                end = time.perf_counter()
                logger.debug("Parsed {} in {:.1f}ms, partial evaluation in {:.1f}ms", self._path, (mid-start)*1000, (end-mid)*1000)
                logger.opt(lazy=True).debug("Tree node count before partial-evaluation {before} and after {after}",
                                            before=lambda: initial_top.reduce(lambda e, *rs: sum(rs) + 1),
                                            after=lambda: top.reduce(lambda e, *rs: sum(rs) + 1))
            except ParseError as exc:
                if top is None:
                    logger.error("Error parsing {} at line {} column {}:\n{}",
                                 self._path, exc.line, exc.column, exc.context)
                else:
                    logger.warning("Unable to re-parse {}, error at line {} column {}:\n{}",
                                   self._path, exc.line, exc.column, exc.context)
            except Exception as exc:
                logger.opt(exception=exc).warning("Error reading program file: {}", self._path)
                top = None
        self._cache['flitter'] = mtime, top
        return top

    def read_csv_vector(self, row_number):
        import csv
        from . import model
        self._touched = time.monotonic()
        mtime = self._path.stat().st_mtime if self._path.exists() else None
        if 'csv' in self._cache and self._cache['csv'][0] == mtime:
            _, reader, rows = self._cache['csv']
        elif mtime is None:
            logger.warning("File not found: {}", self._path)
            reader = None
            rows = []
        else:
            try:
                reader = csv.reader(self._path.open(newline=''))
                logger.debug("Opened CSV file: {}", self._path)
            except Exception as exc:
                logger.opt(exception=exc).warning("Error reading CSV file: {}", self._path)
                reader = None
            rows = []
        while reader is not None and row_number >= len(rows):
            try:
                row = next(reader)
                values = []
                for value in row:
                    try:
                        value = float(value)
                    except ValueError:
                        pass
                    values.append(value)
                rows.append(model.Vector.coerce(values))
            except StopIteration:
                logger.debug("Closed CSV file: {}", self._path)
                reader = None
                break
            except Exception as exc:
                logger.opt(exception=exc).warning("Error reading CSV file: {}", self._path)
                reader = None
        self._cache['csv'] = mtime, reader, rows
        if 0 <= row_number < len(rows):
            return rows[row_number]
        return model.null

    def read_image(self):
        import skia
        self._touched = time.monotonic()
        mtime = self._path.stat().st_mtime if self._path.exists() else None
        if 'image' in self._cache:
            cache_mtime, image = self._cache['image']
            if mtime == cache_mtime:
                return image
        if mtime is None:
            logger.warning("File not found: {}", self._path)
            image = None
        else:
            try:
                image = skia.Image.open(str(self._path))
            except Exception as exc:
                logger.opt(exception=exc).warning("Error reading image file: {}", self._path)
                image = None
            else:
                logger.debug("Read image file: {}", self._path)
        self._cache['image'] = mtime, image
        return image

    def read_video_frames(self, obj, position, loop=False):
        import av
        self._touched = time.monotonic()
        key = 'video', id(obj)
        container = decoder = current_frame = next_frame = None
        frames = []
        ratio = 0
        mtime = self._path.stat().st_mtime if self._path.exists() else None
        if key in self._cache and self._cache[key][0] == mtime:
            _, container, decoder, frames = self._cache[key]
        elif mtime is None:
            logger.warning("File not found: {}", self._path)
        else:
            try:
                container = av.container.open(str(self._path))
                stream = container.streams.video[0]
                ctx = stream.codec_context
                logger.debug("Opened {}x{} {:.0f}fps video file: {}", ctx.width, ctx.height, float(stream.average_rate), self._path)
            except Exception as exc:
                logger.opt(exception=exc).warning("Error reading video file: {}", self._path)
                container = None
        if container is not None:
            try:
                stream = container.streams.video[0]
                if loop:
                    timestamp = stream.start_time + int(position / stream.time_base) % stream.duration
                else:
                    timestamp = stream.start_time + min(max(0, int(position / stream.time_base)), stream.duration)
                count = 0
                while True:
                    if len(frames) >= 2:
                        if timestamp >= frames[0].pts and (frames[-1] is None or timestamp <= frames[-1].pts):
                            break
                        if timestamp < frames[0].pts or (timestamp > frames[1].pts and frames[-1].key_frame):
                            frames = []
                    if not frames:
                        if decoder is not None:
                            decoder.close()
                        logger.trace("Seek video {} to {:.2f}s", self._path, float(timestamp * stream.time_base))
                        container.seek(timestamp, stream=stream)
                        decoder = container.decode(streams=(stream.index,))
                    if decoder is not None:
                        try:
                            frame = next(decoder)
                            count += 1
                        except StopIteration:
                            logger.trace("Hit end of video {}", self._path)
                            decoder = None
                            frame = None
                        frames.append(frame)
                        if len(frames) == 1:
                            logger.trace("Decoding frames from {:.2f}s", float(frames[0].pts * stream.time_base))
                if count > 1:
                    logger.trace("Decoded {} frames to find position {:.2f}s", count, float(timestamp * stream.time_base))
                for current_frame in reversed(frames):
                    if current_frame is not None and current_frame.pts <= timestamp:
                        break
                    next_frame = current_frame
                ratio = (timestamp - current_frame.pts) / (next_frame.pts - current_frame.pts) if next_frame is not None else 0
            except Exception as exc:
                logger.opt(exception=exc).warning("Error reading video file: {}", self._path)
                container = decoder = None
                frames = []
        self._cache[key] = mtime, container, decoder, frames
        return ratio, current_frame, next_frame
        if frames:
            return ratio, *frames
        else:
            return 0, None, None

    def read_trimesh_model(self):
        import trimesh
        self._touched = time.monotonic()
        mtime = self._path.stat().st_mtime if self._path.exists() else None
        if 'trimesh' in self._cache:
            cache_mtime, trimesh_model = self._cache['trimesh']
            if mtime == cache_mtime:
                return trimesh_model
        if mtime is None:
            logger.warning("File not found: {}", self._path)
            trimesh_model = None
        else:
            try:
                trimesh_model = trimesh.load(str(self._path))
            except Exception as exc:
                logger.opt(exception=exc).warning("Error reading model file: {}", self._path)
                trimesh_model = None
            else:
                logger.debug("Read model file: {}", self._path)
        self._cache['trimesh'] = mtime, trimesh_model
        return trimesh_model

    def __str__(self):
        return str(self._path)


class FileCache:
    def __init__(self):
        self._cache = {}
        self._root = Path('.')

    def clean(self, max_age=5):
        cutoff = time.monotonic() - max_age
        for path in list(self._cache):
            cache_path = self._cache[path]
            if cache_path._touched < cutoff:
                cache_path.cleanup()
                del self._cache[path]
                logger.trace("Discarded {}", path)

    def set_root(self, path):
        if isinstance(path, CachePath):
            path = path._path
        else:
            path = Path(path)
        if path.exists():
            if not path.is_dir():
                path = path.parent
            self._root = path
        else:
            self._root = Path('.')

    def __getitem__(self, path):
        path = Path(path)
        if not path.is_absolute():
            path = self._root / path
        key = str(path.resolve())
        if key in self._cache:
            return self._cache[key]
        path = CachePath(path)
        self._cache[key] = path
        return path


SharedCache = FileCache()
