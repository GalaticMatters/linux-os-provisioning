# Loaded with gunicorn -c. cwd is /opt/CTFd; do not inherit a surprise
# gunicorn.conf.py. reload must stay false: plugin .pyc writes would
# otherwise restart the process and re-run alembic on every hit.
# timeout 0: a 120s cap SIGABRT'd the worker (~123s curls).
#
# gthread, one worker: after login the theme holds GET /events (SSE).
# A sync worker served only that connection, so the next curl waited
# until gunicorn killed it (~120s). Threads share one create_app(); do
# not add a second worker (that would boot alembic/plugins twice).
bind = "0.0.0.0:8000"
workers = 1
threads = 8
worker_class = "gthread"
timeout = 0
graceful_timeout = 30
keepalive = 5
max_requests = 0
max_requests_jitter = 0
reload = False
preload_app = False
worker_tmp_dir = "/dev/shm"
accesslog = "-"
errorlog = "-"
capture_output = True
# IP only; do not reverse-resolve clients.
access_log_format = '%(h)s %(t)s "%(r)s" %(s)s %(D)s'
wsgi_app = "wsgi:app"
