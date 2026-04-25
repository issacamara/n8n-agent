
FROM python:3.11-slim AS solar-forecast
LABEL authors="issacamara"

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PORT=8080

WORKDIR scripts/

COPY scripts/requirements.txt .
COPY scripts/main.py .

RUN pip install --no-cache-dir -r requirements.txt

CMD ["functions-framework", "--target=solar_forecast", "--source=main.py", "--port=8080"]
