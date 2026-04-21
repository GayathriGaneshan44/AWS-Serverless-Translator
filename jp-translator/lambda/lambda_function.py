import json
import boto3
import uuid
import logging
from datetime import datetime
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

translate_client = boto3.client("translate")
polly_client     = boto3.client("polly")
s3_client        = boto3.client("s3")

# ── Read from environment variables (set in Lambda console or deploy script) ──
import os
HISTORY_BUCKET = os.environ.get("HISTORY_BUCKET", "jp-translator-history")
AUDIO_BUCKET   = os.environ.get("AUDIO_BUCKET",   "jp-translator-audio")
AUDIO_URL_TTL  = int(os.environ.get("AUDIO_URL_TTL", "3600"))   # seconds


DIRECTION_MAP = {
    "ja-en": ("ja", "en", "Joanna"),    # Joanna = English neural voice
    "en-ja": ("en", "ja", "Takumi"),    # Takumi = Japanese male neural voice
}

CORS_HEADERS = {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "Content-Type,X-Api-Key",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
    "Content-Type":                 "application/json",
}


def lambda_handler(event, context):
    logger.info("Event: %s", json.dumps(event))

    # ── Handle CORS pre-flight ──────────────────────────────────────────────
    if event.get("httpMethod") == "OPTIONS":
        return {"statusCode": 200, "headers": CORS_HEADERS, "body": ""}

    # ── Parse request body ──────────────────────────────────────────────────
    try:
        body = json.loads(event.get("body") or "{}")
        text      = body["text"].strip()
        direction = body["direction"].lower()   # "ja-en" or "en-ja"
        if not text:
            raise ValueError("text is empty")
        if direction not in DIRECTION_MAP:
            raise ValueError(f"direction must be 'ja-en' or 'en-ja', got: {direction}")
    except (KeyError, ValueError) as exc:
        return _error(400, str(exc))

    source_lang, target_lang, voice_id = DIRECTION_MAP[direction]
    request_id = str(uuid.uuid4())
    timestamp  = datetime.utcnow().isoformat() + "Z"

    # ── Step 1: Amazon Translate ────────────────────────────────────────────
    try:
        translation_response = translate_client.translate_text(
            Text=text,
            SourceLanguageCode=source_lang,
            TargetLanguageCode=target_lang,
            Settings={"Formality": "FORMAL"},   # suitable for business context
        )
        translated_text = translation_response["TranslatedText"]
        logger.info("Translated: %s → %s", text[:60], translated_text[:60])
    except ClientError as exc:
        logger.error("Translate error: %s", exc)
        return _error(502, "Translation service error")

    # ── Step 2: Amazon Polly ────────────────────────────────────────────────
    try:
        polly_response = polly_client.synthesize_speech(
            Text=translated_text,
            VoiceId=voice_id,
            OutputFormat="mp3",
            Engine="neural",            # higher-quality neural TTS
            LanguageCode=target_lang if target_lang != "en" else "en-US",
        )
        audio_bytes = polly_response["AudioStream"].read()
    except ClientError as exc:
        logger.error("Polly error: %s", exc)
        return _error(502, "Text-to-speech service error")

    # ── Step 3: Save MP3 to S3 ──────────────────────────────────────────────
    audio_key = f"audio/{timestamp[:10]}/{request_id}.mp3"
    try:
        s3_client.put_object(
            Bucket=AUDIO_BUCKET,
            Key=audio_key,
            Body=audio_bytes,
            ContentType="audio/mpeg",
        )
        audio_url = s3_client.generate_presigned_url(
            "get_object",
            Params={"Bucket": AUDIO_BUCKET, "Key": audio_key},
            ExpiresIn=AUDIO_URL_TTL,
        )
    except ClientError as exc:
        logger.error("S3 audio error: %s", exc)
        return _error(502, "Audio storage error")

    # ── Step 4: Save translation history JSON to S3 ─────────────────────────
    history_record = {
        "requestId":      request_id,
        "timestamp":      timestamp,
        "direction":      direction,
        "sourceText":     text,
        "translatedText": translated_text,
        "audioKey":       audio_key,
    }
    history_key = f"history/{timestamp[:10]}/{request_id}.json"
    try:
        s3_client.put_object(
            Bucket=HISTORY_BUCKET,
            Key=history_key,
            Body=json.dumps(history_record, ensure_ascii=False, indent=2),
            ContentType="application/json",
        )
    except ClientError as exc:
        logger.warning("History save failed (non-fatal): %s", exc)

    # ── Step 5: Return response ─────────────────────────────────────────────
    return {
        "statusCode": 200,
        "headers": CORS_HEADERS,
        "body": json.dumps({
            "requestId":      request_id,
            "sourceText":     text,
            "translatedText": translated_text,
            "audioUrl":       audio_url,
            "direction":      direction,
            "timestamp":      timestamp,
        }, ensure_ascii=False),
    }


def _error(status: int, message: str) -> dict:
    logger.error("Returning %d: %s", status, message)
    return {
        "statusCode": status,
        "headers": CORS_HEADERS,
        "body": json.dumps({"error": message}),
    }
