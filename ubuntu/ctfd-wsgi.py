"""Gunicorn target: Flask app object, created once at import.

Do not expose a WSGI function named application() that gunicorn --factory
could call per request. CTFd's create_app() runs alembic and plugins; that
must happen once per process, not once per HTTP hit.
"""
from CTFd import create_app

app = create_app()
