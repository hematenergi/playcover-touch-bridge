#!/usr/bin/env python3
import pathlib
import runpy
import os

os.environ['PATH'] = '/opt/homebrew/bin:/usr/local/bin:' + os.environ.get('PATH', '/usr/bin:/bin')
runpy.run_path(str(pathlib.Path(__file__).resolve().parent / 'host.py'), run_name='__main__')
