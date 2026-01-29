FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir "huggingface_hub<0.25.0" "gradio==4.36.0"

COPY . .

EXPOSE 7860

ENV GRADIO_SERVER_NAME=0.0.0.0

CMD ["python", "app.py"]
