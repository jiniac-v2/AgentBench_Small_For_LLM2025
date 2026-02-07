FROM python:3.9-slim

# System dependencies for ALFWorld (OpenCV requires libgl1) and envsubst (gettext-base)
RUN apt-get update && \
    apt-get install -y --no-install-recommends libgl1 libglib2.0-0 gettext-base && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENTRYPOINT ["./entrypoint.sh"]
CMD ["src.assigner", "configs/assignments/default.yaml"]
