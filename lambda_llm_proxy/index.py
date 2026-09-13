"""LLM Proxy Lambda — routes free-tier LLM requests with quota and telemetry."""
from __future__ import annotations
import json
import logging
import os
import re
import time
import uuid
import urllib.request
import urllib.error
from datetime import datetime, timezone, timedelta
from typing import Any
import boto3

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

AWS_REGION = os.environ.get("AWS_REGION", "us-east-2")
USAGE_TABLE = os.environ.get("USAGE_TABLE")
TELEMETRY_TABLE = os.environ.get("TELEMETRY_TABLE")
SECRETS_ARN = os.environ.get("SECRETS_ARN")
DEFAULT_USER_DAILY_LIMIT = int(os.environ.get("DEFAULT_USER_DAILY_LIMIT", "100"))
DEFAULT_USER_DAILY_TOKEN_LIMIT = int(os.environ.get("DEFAULT_USER_DAILY_TOKEN_LIMIT", "100000"))

PROVIDER_DAILY_LIMITS = {
    "gemini": {"requests": 1000, "tokens": 1_000_000},
    "openrouter": {"requests": 200, "tokens": 200_000},
    "bedrock": {"requests": 100, "tokens": 100_000},
}

# Bedrock models are tried in order; the first one accessible in the deployed
# region wins. AWS now often requires an inference-profile ARN for Claude, and
# model access must be enabled per account, so we probe several candidates.
BEDROCK_CANDIDATE_MODELS = [
    "anthropic.claude-3-5-haiku-20241022-v1:0",
    "us.anthropic.claude-3-5-haiku-20241022-v1:0",
    "anthropic.claude-3-haiku-20240307-v1:0",
    "anthropic.claude-v2:1",
    "amazon.titan-text-express-v1",
    "meta.llama3-8b-instruct-v1:0",
]

_dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
_secrets = boto3.client("secretsmanager", region_name=AWS_REGION)
_cloudwatch = boto3.client("cloudwatch", region_name=AWS_REGION)
_api_keys: dict[str, str] = {}

# Model ids are restricted to a safe charset. Human-readable UI labels such as
# "Auto (cloud)" must never be forwarded to a provider as a model name.
_MODEL_ID_RE = re.compile(r"^[A-Za-z0-9._:/+-]+$")


def _looks_like_model_id(value: str) -> bool:
    return bool(value) and bool(_MODEL_ID_RE.match(value))


MOE_CODING_MODEL = os.environ.get("MOE_CODING_MODEL", "tencent/hy3")
MOE_IMAGE_MODEL = os.environ.get("MOE_IMAGE_MODEL", "hunyuan/hunyuan-image-v3-text-to-image")
MOE_IMAGE_BASE_URL = os.environ.get("MOE_IMAGE_BASE_URL", "https://api.aimlapi.com")
MOE_IMAGE_ENDPOINT = "/v1/images/generations"

# Mixture-of-Experts routing table. Intent classification (see _classify_intent)
# maps a prompt onto one of these experts. Each expert is bound to a provider
# layer that the proxy already knows how to call, so adding an expert does not
# require any new credential plumbing in the gateway.
MOE_EXPERTS = {
    "coding": {
        "name": "hunyuan3",
        "provider": "openrouter",
        "model": MOE_CODING_MODEL,
        "is_image": False,
    },
    "image": {
        "name": "hunyuanimage3",
        "provider": "aimlapi",
        "model": MOE_IMAGE_MODEL,
        "is_image": True,
        "base_url": MOE_IMAGE_BASE_URL,
        "endpoint": MOE_IMAGE_ENDPOINT,
    },
}

_CODING_INTENT_RE = re.compile(
    r"\b(?:code|function|program(?:ming)?|coding|debug|compile|algorithm|script"
    r"|implement|refactor|lint|syntax error|stack ?trace|endpoint|lambda|class "
    r"|def |import |loop|iterate|recursion|sql|query|html|css|javascript"
    r"|typescript|python|java|c\+\+|rust|golang|backend|frontend|fullstack"
    r"|full stack|test case|unit test)\b",
    re.IGNORECASE,
)
_IMAGE_INTENT_RE = re.compile(
    r"\b(?:generate|create|draw|paint|make|render|produce|give me|show me|i need"
    r"|make me)\b.*?\b(?:image|picture|photo|illustration|art|drawing|painting|icon"
    r"|logo|wallpaper|character|creature|scene|portrait|sprite|concept art)\b"
    r"|\b(?:text ?-?to-? ?image|text2image|stable diffusion|diffusion model"
    r"|concept art|digital art|visualize|visualize a|sdxl|midjourney)\b",
    re.IGNORECASE,
)


def _classify_intent(prompt: str) -> str:
    """Classify a prompt into a Mixture-of-Experts intent bucket.

    Image-generation markers are checked first (high precision) so that a coding
    prompt merely mentioning an artifact (e.g. "icon") still routes to the coding
    expert; a prompt that matches both is treated as an image-generation request.
    """
    if _IMAGE_INTENT_RE.search(prompt):
        return "image"
    if _CODING_INTENT_RE.search(prompt):
        return "coding"
    return "general"


def _select_moe_expert(prompt: str, mode: str = "") -> dict[str, Any] | None:
    """Return the expert spec for the request's intent/mode, or None to keep the
    normal provider fallback chain.

    An explicit `mode` ("code"/"image") from the client takes precedence and
    routes directly to the matching expert; otherwise the prompt is classified
    by intent. An expert is only selected when its upstream provider has a
    configured API key (Bedrock is always considered reachable). When the key is
    missing we return None so the request falls through to the regular providers
    instead of failing with a hard error.
    """
    if mode == "code":
        intent = "coding"
    elif mode == "image":
        intent = "image"
    else:
        intent = _classify_intent(prompt)
    expert = MOE_EXPERTS.get(intent)
    if expert is None:
        return None
    provider = expert["provider"]
    if provider != "bedrock" and not _get_api_key(provider):
        return None
    return expert


def _http_post(url: str, headers: dict[str, str], payload: dict[str, Any], timeout: int = 30) -> tuple[int, dict[str, Any]]:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            try:
                body = json.loads(raw)
            except (json.JSONDecodeError, ValueError):
                body = {"_raw": raw[:500]}
            return resp.status, body
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace") if exc.fp else ""
        try:
            body = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            body = {"_raw": raw[:500]}
        return exc.code, body


def _http_post_retry(url: str, headers: dict[str, str], payload: dict[str, Any], timeout: int = 30, retries: int = 2) -> tuple[int, dict[str, Any]]:
    """POST with retry on transient upstream failures (network errors, 429, 5xx)."""
    last_exc: Exception | None = None
    for _ in range(retries + 1):
        try:
            status, body = _http_post(url, headers, payload, timeout)
            if status == 429 or status >= 500:
                last_exc = RuntimeError(f"Transient upstream status {status}")
                continue
            return status, body
        except Exception as exc:  # network/DNS/timeout
            last_exc = exc
            continue
    raise last_exc or RuntimeError("Upstream request failed")


def _get_api_key(provider: str) -> str:
    # Allow the key to be injected directly as an env var (e.g. via Terraform),
    # which is the easiest way to enable a provider without editing the secret.
    env_key = os.environ.get(f"{provider.upper()}_API_KEY")
    if env_key:
        return env_key
    if provider in _api_keys:
        return _api_keys[provider]
    try:
        secret_value = _secrets.get_secret_value(SecretId=SECRETS_ARN)
        secret_data = json.loads(secret_value["SecretString"])
        for key in (f"{provider}/api_key", f"{provider}_api_key", f"{provider.upper()}_API_KEY", "api_key"):
            val = secret_data.get(key, "")
            if val:
                _api_keys[provider] = val
                return val
    except Exception:
        return ""
    return ""


def _usage_table():
    if not USAGE_TABLE:
        raise RuntimeError("USAGE_TABLE is not configured")
    return _dynamodb.Table(USAGE_TABLE)


def _telemetry_table():
    if not TELEMETRY_TABLE:
        raise RuntimeError("TELEMETRY_TABLE is not configured")
    return _dynamodb.Table(TELEMETRY_TABLE)


def _today_str() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _end_of_day_epoch() -> int:
    now = datetime.now(timezone.utc)
    end = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return int(end.timestamp())


def _quota_key(user_id: str, provider: str, date: str) -> str:
    return f"{user_id}#{provider}#{date}"


def _check_quota(user_id: str, provider: str) -> dict[str, Any]:
    table = _usage_table()
    today = _today_str()
    key = _quota_key(user_id, provider, today)
    try:
        resp = table.get_item(Key={"user_id#provider#date": key})
        item = resp.get("Item", {})
        if not item:
            item = {
                "user_id#provider#date": key,
                "user_id": user_id,
                "provider": provider,
                "date": today,
                "requests": 0,
                "tokens_in": 0,
                "tokens_out": 0,
                "last_reset": datetime.now(timezone.utc).isoformat(),
                "expire_at": _end_of_day_epoch(),
            }
            table.put_item(Item=item)
        return item
    except Exception:
        return {"requests": 0, "tokens_in": 0, "tokens_out": 0}


def _increment_quota(user_id: str, provider: str, requests_delta: int, tokens_in: int, tokens_out: int) -> None:
    table = _usage_table()
    key = _quota_key(user_id, provider, _today_str())
    try:
        table.update_item(
            Key={"user_id#provider#date": key},
            UpdateExpression="ADD requests :r, tokens_in :ti, tokens_out :to",
            ExpressionAttributeValues={
                ":r": requests_delta,
                ":ti": tokens_in,
                ":to": tokens_out,
            },
        )
    except Exception:
        pass


def _enforce_quota(user_id: str, provider: str, estimated_tokens: int = 0) -> dict[str, Any]:
    usage = _check_quota(user_id, provider)
    provider_limits = PROVIDER_DAILY_LIMITS.get(provider, {})
    user_req_limit = DEFAULT_USER_DAILY_LIMIT
    user_tok_limit = DEFAULT_USER_DAILY_TOKEN_LIMIT

    current_req = usage.get("requests", 0)
    current_tok = usage.get("tokens_in", 0) + usage.get("tokens_out", 0)

    if current_req >= user_req_limit:
        return {"error": "User daily request quota exceeded", "retry_after": "24h"}
    if current_tok + estimated_tokens > user_tok_limit:
        return {"error": "User daily token quota exceeded", "retry_after": "24h"}
    if provider_limits:
        if current_req >= provider_limits.get("requests", 999999):
            return {"error": "Provider daily request limit reached", "retry_after": "24h"}
        if current_tok + estimated_tokens > provider_limits.get("tokens", 9_999_999):
            return {"error": "Provider daily token limit reached", "retry_after": "24h"}
    return {}


def _emit_metric(metric_name: str, value: float, provider: str, unit: str = "Count") -> None:
    try:
        _cloudwatch.put_metric_data(
            Namespace="sQuark/LLM",
            MetricData=[
                {
                    "MetricName": metric_name,
                    "Dimensions": [{"Name": "Provider", "Value": provider}],
                    "Value": value,
                    "Unit": unit,
                    "Timestamp": datetime.now(timezone.utc),
                }
            ],
        )
    except Exception:
        pass


def _record_telemetry(user_id: str, provider: str, model: str, tokens_in: int, tokens_out: int, latency_ms: int, status: str, error: str = "") -> None:
    try:
        _telemetry_table().put_item(
            Item={
                "request_id": str(uuid.uuid4()),
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "user_id": user_id,
                "provider": provider,
                "model": model,
                "tokens_in": tokens_in,
                "tokens_out": tokens_out,
                "latency_ms": latency_ms,
                "status": status,
                "error": error,
                "expire_at": int((datetime.now(timezone.utc) + timedelta(days=90)).timestamp()),
            }
        )
    except Exception:
        pass


def _call_gemini(prompt: str, model: str, api_key: str, timeout: int = 30) -> dict[str, Any]:
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"
    payload = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": 0.7, "maxOutputTokens": 4096},
    }
    start = time.time()
    status_code, body = _http_post_retry(url, {"Content-Type": "application/json"}, payload, timeout)
    latency = int((time.time() - start) * 1000)
    if status_code >= 400:
        raise RuntimeError(f"Gemini error {status_code}: {body}")
    text = ""
    tokens_in = len(prompt.split())
    tokens_out = 0
    if body.get("candidates"):
        parts = body["candidates"][0].get("content", {}).get("parts", [])
        if parts:
            text = parts[0].get("text", "")
            tokens_out = len(text.split())
    usage = body.get("usageMetadata", {})
    tokens_in = usage.get("promptTokenCount", tokens_in)
    tokens_out = usage.get("candidatesTokenCount", tokens_out)
    return {"text": text, "tokens_in": tokens_in, "tokens_out": tokens_out, "latency_ms": latency}


def _call_openrouter(prompt: str, model: str, api_key: str, timeout: int = 30) -> dict[str, Any]:
    url = "https://openrouter.ai/api/v1/chat/completions"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are sQuark's assistant. Be concise and helpful."},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.7,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://squark-browser.local",
        "X-Title": "sQuark Browser",
    }
    start = time.time()
    status_code, body = _http_post_retry(url, headers, payload, timeout)
    latency = int((time.time() - start) * 1000)
    if status_code >= 400:
        raise RuntimeError(f"OpenRouter error {status_code}: {body}")
    text = ""
    tokens_in = 0
    tokens_out = 0
    if body.get("choices"):
        text = body["choices"][0].get("message", {}).get("content", "")
        tokens_out = len(text.split())
    usage = body.get("usage", {})
    tokens_in = usage.get("prompt_tokens", 0)
    tokens_out = usage.get("completion_tokens", tokens_out)
    return {"text": text, "tokens_in": tokens_in, "tokens_out": tokens_out, "latency_ms": latency}


def _call_image_generation(
    prompt: str,
    api_key: str,
    base_url: str,
    model: str,
    endpoint: str,
    timeout: int = 30,
) -> dict[str, Any]:
    """Call an OpenAI-compatible text-to-image endpoint (HunyuanImage 3.0)."""
    url = f"{base_url}{endpoint}"
    payload = {"model": model, "prompt": prompt, "n": 1}
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    start = time.time()
    status_code, body = _http_post_retry(url, headers, payload, timeout)
    latency = int((time.time() - start) * 1000)
    if status_code >= 400:
        raise RuntimeError(f"Image provider error {status_code}: {body}")
    image_url = ""
    data = body.get("data") or []
    if isinstance(data, list) and data:
        image_url = data[0].get("url", "") or ""
    tokens_in = len(prompt.split())
    return {
        "text": image_url,
        "image_url": image_url,
        "tokens_in": tokens_in,
        "tokens_out": 0,
        "latency_ms": latency,
    }


def _record_moe_success(
    user_id: str, provider: str, expert: dict[str, Any], result: dict[str, Any]
) -> None:
    _emit_metric("LLMRequests", 1, provider)
    _emit_metric("LLMTokens", float(result.get("tokens_in", 0)), provider)
    _emit_metric("LLMTokens", float(result.get("tokens_out", 0)), f"{provider}:Output")
    _emit_metric("LLMLatency", float(result.get("latency_ms", 0)), provider, "Milliseconds")
    _increment_quota(
        user_id, provider, 1, result.get("tokens_in", 0), result.get("tokens_out", 0)
    )
    _record_telemetry(
        user_id,
        provider,
        expert["model"],
        result.get("tokens_in", 0),
        result.get("tokens_out", 0),
        result.get("latency_ms", 0),
        "success",
    )


def _call_moe_expert(
    prompt: str, expert: dict[str, Any], api_key: str, timeout: int = 30
) -> dict[str, Any]:
    """Dispatch a non-streaming request to the selected MoE expert."""
    model = expert["model"]
    if expert["is_image"]:
        return _call_image_generation(
            prompt, api_key, expert["base_url"], model, expert["endpoint"], timeout
        )
    return _call_openrouter(prompt, model, api_key, timeout)


def _stream_moe_expert(
    prompt: str, expert: dict[str, Any], api_key: str, timeout: int = 30
):
    """Yield tokens from the selected MoE expert for the streaming path."""
    model = expert["model"]
    if expert["is_image"]:
        result = _call_image_generation(
            prompt, api_key, expert["base_url"], model, expert["endpoint"], timeout
        )
        if result.get("text"):
            yield result["text"]
        return
    yield from _stream_openrouter(prompt, model, api_key, timeout)


def _try_moe_nonstream(prompt: str, user_id: str, mode: str = "") -> dict[str, Any] | None:
    """Attempt the MoE expert for a non-streaming request.

    Returns the success payload, or None when no expert applies (or the expert
    failed). Returning None lets the caller fall through to the normal provider
    fallback chain, preserving the "one upstream hiccup is not a 502" contract.
    """
    expert = _select_moe_expert(prompt, mode)
    if expert is None:
        return None
    provider = expert["provider"]
    if _enforce_quota(user_id, provider, estimated_tokens=len(prompt.split())):
        return None
    api_key = _get_api_key(provider) if provider != "bedrock" else ""
    try:
        result = _call_moe_expert(prompt, expert, api_key)
    except Exception as exc:
        LOGGER.warning("MoE expert %s failed, falling back to provider chain: %s", expert["name"], exc)
        return None
    _record_moe_success(user_id, provider, expert, result)
    payload = {
        "text": result.get("text", ""),
        "provider": provider,
        "model": expert["model"],
        "tokens_in": result.get("tokens_in", 0),
        "tokens_out": result.get("tokens_out", 0),
        "latency_ms": result.get("latency_ms", 0),
    }
    if expert["is_image"]:
        payload["image_url"] = result.get("image_url", "")
    return payload


def _call_bedrock(prompt: str, model: str, region: str, timeout: int = 30) -> dict[str, Any]:
    client = boto3.client("bedrock-runtime", region_name=region)
    start = time.time()
    response = client.invoke_model(
        modelId=model,
        body=json.dumps({"anthropic_version": "bedrock-2023-05-31", "max_tokens": 4096, "messages": [{"role": "user", "content": prompt}]}),
    )
    latency = int((time.time() - start) * 1000)
    body = json.loads(response["body"].read())
    text = ""
    tokens_in = 0
    tokens_out = 0
    if body.get("content"):
        text = body["content"][0].get("text", "")
        tokens_out = len(text.split())
    usage = body.get("usage", {})
    tokens_in = usage.get("input_tokens", 0)
    tokens_out = usage.get("output_tokens", tokens_out)
    return {"text": text, "tokens_in": tokens_in, "tokens_out": tokens_out, "latency_ms": latency}


def _stream_gemini(prompt: str, model: str, api_key: str, timeout: int = 30):
    """Yield text chunks from Gemini's SSE streaming endpoint."""
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?alt=sse&key={api_key}"
    payload = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": 0.7, "maxOutputTokens": 4096},
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace")
            if not line.startswith("data:"):
                continue
            payload_str = line[len("data:"):].strip()
            if not payload_str or payload_str == "[DONE]":
                continue
            try:
                obj = json.loads(payload_str)
            except Exception:
                continue
            try:
                parts = obj["candidates"][0]["content"]["parts"]
                text = "".join(p.get("text", "") for p in parts if p.get("text"))
            except (KeyError, IndexError, TypeError):
                continue
            if text:
                yield text


def _stream_openrouter(prompt: str, model: str, api_key: str, timeout: int = 30):
    """Yield text chunks from OpenRouter's SSE streaming endpoint."""
    url = "https://openrouter.ai/api/v1/chat/completions"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are sQuark's assistant. Be concise and helpful."},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.7,
        "stream": True,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://squark-browser.local",
        "X-Title": "sQuark Browser",
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace")
            if not line.startswith("data:"):
                continue
            payload_str = line[len("data:"):].strip()
            if not payload_str or payload_str == "[DONE]":
                continue
            try:
                obj = json.loads(payload_str)
            except Exception:
                continue
            try:
                delta = obj["choices"][0]["delta"].get("content", "")
            except (KeyError, IndexError, TypeError):
                continue
            if delta:
                yield delta


def _stream_bedrock(prompt: str, model: str, region: str, timeout: int = 30):
    """Yield text chunks from Bedrock's response-stream API."""
    client = boto3.client("bedrock-runtime", region_name=region)
    response = client.invoke_model_with_response_stream(
        modelId=model,
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 4096,
            "messages": [{"role": "user", "content": prompt}],
        }),
        contentType="application/json",
        accept="application/json",
    )
    for event in response["body"]:
        chunk = event.get("chunk")
        if not chunk:
            continue
        try:
            data = json.loads(chunk["bytes"])
        except Exception:
            continue
        text = data.get("delta", {}).get("text", "")
        if text:
            yield text


def _stream_bedrock_candidates(prompt: str, candidates: list[str], region: str, timeout: int = 30):
    for cand in candidates:
        try:
            yield from _stream_bedrock(prompt, cand, region, timeout)
            return
        except Exception as exc:
            if "invalid" in str(exc).lower() or "ValidationException" in str(exc):
                continue
            raise


def _write_sse_token(stream, token: str) -> None:
    stream.write(f"data: {json.dumps({'token': token})}\n\n".encode("utf-8"))


def _write_sse_error(stream, status: int, message: str) -> None:
    stream.write(f"HTTP/1.1 {status} OK\r\nContent-Type: text/event-stream\r\n\r\n".encode("utf-8"))
    stream.write(f"data: {json.dumps({'error': message})}\n\n".encode("utf-8"))


def _write_json_response(stream, response: dict[str, Any]) -> None:
    """Write a normal JSON API response onto a Lambda response stream."""
    stream.write(f"HTTP/1.1 {response['statusCode']} OK\r\n".encode("utf-8"))
    stream.write(b"Content-Type: application/json\r\n\r\n")
    stream.write(response["body"].encode("utf-8"))


def stream_response(event: dict[str, Any], context: Any) -> None:
    """Stream the LLM response as Server-Sent Events onto context.response_stream."""
    LOGGER.info("LLM proxy stream request: %s", json.dumps(event)[:500])
    try:
        body = json.loads(event.get("body", "{}"))
    except json.JSONDecodeError:
        _write_sse_error(context.response_stream, 400, "Invalid JSON body")
        return

    user_id = body.get("user_id", "anonymous")
    requested_provider = body.get("provider", "gemini")
    model = body.get("model", "")
    prompt = body.get("prompt", "")
    mode = body.get("mode", "")
    if not prompt:
        _write_sse_error(context.response_stream, 400, "Missing 'prompt'")
        return

    provider_order = [requested_provider] + [p for p in ("gemini", "openrouter", "bedrock") if p != requested_provider]

    context.response_stream.write(
        b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
    )

    sent_any = False
    last_error = ""

    # Mixture-of-Experts first: intent-based expert routing (Hunyuan-3 for
    # coding, HunyuanImage 3.0 for image generation). On failure or when no key
    # is configured, fall through to the standard provider chain below.
    expert = _select_moe_expert(prompt, mode)
    if expert is not None:
        provider = expert["provider"]
        quota_error = _enforce_quota(user_id, provider, estimated_tokens=len(prompt.split()))
        if not quota_error:
            try:
                api_key = _get_api_key(provider) if provider != "bedrock" else ""
                for token in _stream_moe_expert(prompt, expert, api_key):
                    sent_any = True
                    _write_sse_token(context.response_stream, token)
                if sent_any:
                    context.response_stream.write(b"data: [DONE]\n\n")
                    return
            except Exception as exc:
                LOGGER.warning("MoE expert %s failed, falling back to provider chain: %s", expert["name"], exc)
                last_error = str(exc)
                if sent_any:
                    context.response_stream.write(b"data: [DONE]\n\n")
                    return

    for provider in provider_order:
        quota_error = _enforce_quota(user_id, provider, estimated_tokens=len(prompt.split()))
        if quota_error:
            last_error = quota_error.get("error", "")
            continue
        api_key = _get_api_key(provider)
        if not api_key and provider != "bedrock":
            last_error = f"API key for {provider} is not configured"
            continue
        try:
            if provider == "gemini":
                used_model = model or "gemini-3.6-flash"
                if used_model in ("gemini-1.5-flash", "gemini-1.5-flash-latest", "gemini-1.5-pro", "gemini-2.0-flash", "gemini-2.0-pro", "gemini-2.5-flash", "gemini-2.5-pro", "gemini-pro", "gemini-3-pro", "gemini-3.6-pro"):
                    used_model = "gemini-3.6-flash"
                if not _looks_like_model_id(used_model):
                    used_model = "gemini-3.6-flash"
                gen = _stream_gemini(prompt, used_model, api_key)
            elif provider == "openrouter":
                used_model = model or "meta-llama/llama-3.1-8b-instruct:free"
                gen = _stream_openrouter(prompt, used_model, api_key)
            elif provider == "bedrock":
                candidates = [model] if (model and _looks_like_model_id(model)) else list(BEDROCK_CANDIDATE_MODELS)
                gen = _stream_bedrock_candidates(prompt, candidates, AWS_REGION)
            else:
                last_error = f"Unsupported provider: {provider}"
                continue

            for token in gen:
                sent_any = True
                _write_sse_token(context.response_stream, token)
            if sent_any:
                break
        except Exception as exc:
            LOGGER.warning("Streaming provider %s failed: %s", provider, exc)
            last_error = str(exc)
            if sent_any:
                break
            continue

    if not sent_any:
        _write_sse_error(context.response_stream, 502, f"All providers failed. Last error: {last_error}")
    try:
        context.response_stream.write(b"data: [DONE]\n\n")
    except Exception:
        pass


def _response(status_code: int, payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Entry point.

    When invoked in Lambda response-streaming mode (HTTP API integration with
    payload_format_version = "1.0"), `context.response_stream` is present. In
    that case we either stream Server-Sent Events (when `stream: true`) or write
    the normal JSON response back onto the stream (so non-streaming clients keep
    working). Otherwise we return the standard proxy dict.
    """
    if getattr(context, "response_stream", None) is not None:
        try:
            parsed = json.loads(event.get("body", "{}")) if isinstance(event.get("body"), str) else (event.get("body") or {})
        except Exception:
            parsed = {}
        if parsed.get("stream"):
            stream_response(event, context)
        else:
            _write_json_response(context.response_stream, _handle_non_stream(event, context))
        return None
    return _handle_non_stream(event, context)


def _handle_non_stream(event: dict[str, Any], context: Any) -> dict[str, Any]:
    LOGGER.info("LLM proxy request: %s", json.dumps(event)[:500])
    try:
        body = json.loads(event.get("body", "{}"))
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON body"})

    user_id = body.get("user_id", "anonymous")
    requested_provider = body.get("provider", "gemini")
    model = body.get("model", "")
    prompt = body.get("prompt", "")
    mode = body.get("mode", "")
    if not prompt:
        return _response(400, {"error": "Missing 'prompt'"})

    # Mixture-of-Experts: intent-based expert routing (Hunyuan-3 for coding,
    # HunyuanImage 3.0 for image generation). On failure or when no key is
    # configured, fall through to the standard provider chain below.
    moe_payload = _try_moe_nonstream(prompt, user_id, mode)
    if moe_payload is not None:
        return _response(200, moe_payload)

    # Try providers in order: the requested one first, then known fallbacks.
    # A single upstream hiccup should not surface as a 502 to the browser.
    provider_order = [requested_provider] + [p for p in ("gemini", "openrouter", "bedrock") if p != requested_provider]

    result: dict[str, Any] = {"text": "", "tokens_in": 0, "tokens_out": 0, "latency_ms": 0}
    used_provider: str | None = None
    used_model = model
    last_error = ""

    for provider in provider_order:
        quota_error = _enforce_quota(user_id, provider, estimated_tokens=len(prompt.split()))
        if quota_error:
            last_error = quota_error.get("error", "")
            continue

        api_key = _get_api_key(provider)
        if not api_key and provider != "bedrock":
            last_error = f"API key for {provider} is not configured"
            continue

        try:
            if provider == "gemini":
                used_model = model or "gemini-3.6-flash"
                # Older Gemini models were deprecated/removed by Google; remap stale requests.
                if used_model in ("gemini-1.5-flash", "gemini-1.5-flash-latest", "gemini-1.5-pro", "gemini-2.0-flash", "gemini-2.0-pro", "gemini-2.5-flash", "gemini-2.5-pro", "gemini-pro", "gemini-3-pro", "gemini-3.6-pro"):
                    used_model = "gemini-3.6-flash"
                # Guard against UI labels / garbage being sent as the model id.
                if not _looks_like_model_id(used_model):
                    used_model = "gemini-3.6-flash"
                result = _call_gemini(prompt, used_model, api_key)
            elif provider == "openrouter":
                used_model = model or "meta-llama/llama-3.1-8b-instruct:free"
                result = _call_openrouter(prompt, used_model, api_key)
            elif provider == "bedrock":
                # Only trust an explicit, well-formed model id; otherwise probe
                # the known-good candidate list.
                candidates = [model] if (model and _looks_like_model_id(model)) else list(BEDROCK_CANDIDATE_MODELS)
                tried = []
                ok = False
                for cand in candidates:
                    tried.append(cand)
                    try:
                        result = _call_bedrock(prompt, cand, AWS_REGION)
                        used_model = cand
                        ok = True
                        break
                    except Exception as exc:  # retry on invalid/inaccessible model
                        if "invalid" in str(exc).lower() or "ValidationException" in str(exc):
                            continue
                        raise
                if not ok:
                    raise RuntimeError(f"Bedrock model unavailable (tried: {', '.join(tried)})")
            else:
                raise RuntimeError(f"Unsupported provider: {provider}")

            used_provider = provider
            break
        except Exception as exc:
            LOGGER.warning("Provider %s failed, trying next: %s", provider, exc)
            last_error = str(exc)
            continue

    if used_provider is not None:
        _emit_metric("LLMRequests", 1, used_provider)
        _emit_metric("LLMTokens", float(result.get("tokens_in", 0)), used_provider, "Count")
        _emit_metric("LLMTokens", float(result.get("tokens_out", 0)), f"{used_provider}:Output", "Count")
        _emit_metric("LLMLatency", float(result.get("latency_ms", 0)), used_provider, "Milliseconds")
        _increment_quota(user_id, used_provider, 1, result.get("tokens_in", 0), result.get("tokens_out", 0))
        _record_telemetry(user_id, used_provider, used_model, result.get("tokens_in", 0), result.get("tokens_out", 0), result.get("latency_ms", 0), "success")
        return _response(200, {
            "text": result.get("text", ""),
            "provider": used_provider,
            "model": used_model,
            "tokens_in": result.get("tokens_in", 0),
            "tokens_out": result.get("tokens_out", 0),
            "latency_ms": result.get("latency_ms", 0),
        })

    LOGGER.error("All providers failed. Last error: %s", last_error)
    _emit_metric("LLMErrors", 1, requested_provider)
    _record_telemetry(user_id, requested_provider, model, 0, 0, 0, "error", last_error)
    return _response(502, {"error": f"All providers failed. Last error: {last_error}"})
