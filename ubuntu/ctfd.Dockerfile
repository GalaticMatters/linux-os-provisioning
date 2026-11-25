FROM cybersecurity-ubuntu-ssh:1

# CTFd in the same Kata Ubuntu family as ubuntuserver/vai. Do not use
# ctfd/ctfd (that image is runc). sshd still comes from the base image.
# Build cybersecurity-ubuntu-ssh:1 first (docker compose build ubuntu01).
ARG CTFD_VERSION=3.7.7

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-dev \
        python3-pip \
        build-essential \
        libffi-dev \
        libssl-dev \
        git \
        pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 --branch "${CTFD_VERSION}" https://github.com/CTFd/CTFd.git /opt/CTFd \
    && python3 -m venv /opt/CTFd/.venv \
    && /opt/CTFd/.venv/bin/pip install --no-cache-dir -U pip wheel \
    && /opt/CTFd/.venv/bin/pip install --no-cache-dir -r /opt/CTFd/requirements.txt \
    && /opt/CTFd/.venv/bin/pip install --no-cache-dir gunicorn \
    && mkdir -p /var/lib/ctfd

COPY ubuntu/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY ubuntu/kata-net.sh /usr/local/bin/kata-net.sh
COPY ubuntu/ctfd-ensure-admin.py /usr/local/bin/ctfd-ensure-admin.py
COPY ubuntu/ctfd-wsgi.py /opt/CTFd/wsgi.py
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/kata-net.sh /usr/local/bin/ctfd-ensure-admin.py

WORKDIR /opt/CTFd
EXPOSE 22 8000
