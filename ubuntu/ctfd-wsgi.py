"""Gunicorn loads this module once per worker. create_app() must not run per HTTP request."""
from CTFd import create_app

application = create_app()
