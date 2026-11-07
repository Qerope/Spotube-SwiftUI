FROM python:3.12-slim
LABEL app=spotube
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg curl unzip ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL "https://github.com/denoland/deno/releases/latest/download/deno-$(uname -m)-unknown-linux-gnu.zip" -o /tmp/d.zip \
 && unzip -q /tmp/d.zip -d /usr/local/bin && rm /tmp/d.zip
RUN pip install --no-cache-dir "fastapi>=0.115" "uvicorn[standard]>=0.30" yt-dlp
COPY app /app
WORKDIR /app
EXPOSE 8770
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8770", "--proxy-headers", "--forwarded-allow-ips", "*", "--no-access-log"]
