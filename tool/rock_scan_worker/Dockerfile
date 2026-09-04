# The Linux/cloud path. The PRIMARY target is a Windows gaming PC with an
# NVIDIA card — see README.md — and this image is the secondary one.
#
# Ubuntu's packaged COLMAP is built WITHOUT CUDA, so this image reconstructs
# on the CPU: correct, roughly an order of magnitude slower, and unable to
# run the `--dense` tier at all. That is a deliberate trade for an image that
# builds anywhere with no NVIDIA toolchain. For a GPU container, swap the
# base for a CUDA COLMAP image and keep everything below identical:
#
#     FROM colmap/colmap:latest
#     RUN apt-get update && apt-get install -y --no-install-recommends \
#           ffmpeg python3 python3-pip && rm -rf /var/lib/apt/lists/*
#
# ...then run it with `--gpus all`.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        colmap \
        ffmpeg \
        python3 \
        python3-pip \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt ./
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt

COPY rock_scan_worker ./rock_scan_worker

# Scratch space for the video, frames and the COLMAP database of the job in
# flight. Mount a real volume: a phone video plus its frames is easily a few
# gigabytes, and the container layer is the wrong place for that.
VOLUME ["/work"]

# Credentials arrive as environment variables at RUN time and are never baked
# into an image layer:
#   docker run --rm \
#     -e SUPABASE_URL -e SUPABASE_SERVICE_ROLE_KEY \
#     -v rock-scan-work:/work masi-rock-scan-worker
ENTRYPOINT ["python3", "-m", "rock_scan_worker"]
CMD ["run", "--work-dir", "/work"]
