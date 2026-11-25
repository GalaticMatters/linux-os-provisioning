"""Gunicorn WSGI target. CTFd has no Flask `db` command; create_app() runs
alembic/plugins once at import. The callable below must not invoke create_app
again (that is the 80s-per-hit path)."""
from CTFd import create_app

app = create_app()


def application(environ, start_response):
    return app(environ, start_response)

