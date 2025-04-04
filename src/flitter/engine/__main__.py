"""
Flitter main entry point
"""

import argparse
import asyncio
import os
from pathlib import Path
import sys

from flitter import configure_logger, __version__, setproctitle
from .control import EngineController
from ..language.parser import convert_number_to_float, convert_timecode_to_float
from ..model import Vector


def keyvalue(text):
    key, value = text.split('=', 1)
    values = value.split(';')
    for i in range(len(values)):
        if values[i].startswith(':'):
            values[i] = float(Vector.symbol(values[i][1:]))
            continue
        try:
            values[i] = convert_number_to_float(values[i])
            continue
        except ValueError:
            pass
        try:
            values[i] = convert_timecode_to_float(values[i])
        except ValueError:
            pass
    return key, values


def main():
    setproctitle('flitter')
    parser = argparse.ArgumentParser(description=f"Flitter language interpreter, version {__version__}")
    parser.set_defaults(level=None)
    levels = parser.add_mutually_exclusive_group()
    levels.add_argument('--trace', action='store_const', const='TRACE', dest='level', help="Trace logging")
    levels.add_argument('--debug', action='store_const', const='DEBUG', dest='level', help="Debug logging")
    levels.add_argument('--verbose', action='store_const', const='INFO', dest='level', help="Informational logging")
    levels.add_argument('--quiet', action='store_const', const='WARNING', dest='level', help="Only log warnings and errors")
    parser.add_argument('--profile', action='store_true', default=False, help="Run with profiling")
    parser.add_argument('--fps', type=int, default=60, help="Target framerate")
    parser.add_argument('--screen', type=int, default=0, help="Default screen number")
    parser.add_argument('--fullscreen', action='store_true', default=False, help="Default to full screen")
    parser.add_argument('--vsync', action='store_true', default=False, help="Default to window vsync")
    parser.add_argument('--state', type=str, help="State save/restore file")
    parser.add_argument('--resetonswitch', action='store_true', default=False, help="Reset state when switching pages")
    parser.add_argument('--nosimplify', action='store_true', default=False, help="Disable the language simplifier")
    parser.add_argument('--simplifystate', type=convert_timecode_to_float, default=10, help="Simplify on state after stable period")
    parser.add_argument('--lockstep', action='store_true', default=False, help="Run clock in non-realtime mode")
    parser.add_argument('--define', '-D', action='append', default=[], type=keyvalue, dest='defines', help="Define name for evaluation")
    parser.add_argument('--vmstats', action='store_true', default=False, help="Report VM statistics")
    parser.add_argument('--runtime', type=convert_timecode_to_float, help="Seconds to run for before exiting")
    parser.add_argument('--modelcache', type=convert_timecode_to_float, default=300, help="Seconds to cache models for")
    parser.add_argument('--offscreen', action='store_true', default=False, help="Swap windows for offscreens")
    parser.add_argument('--opengles', action='store_true', default=False, help="Use OpenGL ES")
    parser.add_argument('program', nargs='+', help="Program(s) to load")
    args = parser.parse_args()
    logger = configure_logger(args.level)
    if args.opengles and sys.platform == 'darwin':
        chrome_path = Path('/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Libraries')
        if chrome_path.exists() and 'DYLD_FALLBACK_LIBRARY_PATH' not in os.environ:
            os.environ['DYLD_FALLBACK_LIBRARY_PATH'] = str(chrome_path)
            logger.debug("Re-exec with Chrome ANGLE libraries...")
            return os.execlp(sys.argv[0], *sys.argv)
    logger.info("Flitter version {}", __version__)
    controller = EngineController(target_fps=args.fps, screen=args.screen, fullscreen=args.fullscreen, vsync=args.vsync,
                                  state_file=args.state, reset_on_switch=args.resetonswitch, state_simplify_wait=args.simplifystate,
                                  realtime=not args.lockstep, defined_names=dict(args.defines), vm_stats=args.vmstats,
                                  run_time=args.runtime, offscreen=args.offscreen, disable_simplifier=args.nosimplify,
                                  opengl_es=args.opengles, model_cache_time=args.modelcache)
    for program in args.program:
        controller.load_page(program)

    try:
        if args.profile:
            import cProfile
            cProfile.runctx('asyncio.run(controller.run())', globals(), locals(), sort='tottime')
        else:
            asyncio.run(controller.run())
    except KeyboardInterrupt:
        logger.info("Exited on keyboard interrupt")
    except Exception:
        logger.error("Unexpected exception in flitter")
        raise
    finally:
        logger.complete()


if __name__ == '__main__':
    main()
