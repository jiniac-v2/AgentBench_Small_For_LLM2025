FROM python:3.9-slim

# System dependencies:
#   libgl1, libglib2.0-0: ALFWorld (OpenCV)
#   gettext-base: envsubst for config templating
#   curl: vLLM inference test
RUN apt-get update && \
    apt-get install -y --no-install-recommends libgl1 libglib2.0-0 gettext-base curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENTRYPOINT ["./entrypoint.sh"]
