"""Minimal WebSocket orchestrator for the sQuark AI browser stack."""
from __future__ import annotations
import json
import logging
import os
from datetime import datetime, timezone
from typing import Any
import boto3
LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
SESSION_TABLE = os.environ.get("SESSION_TABLE")
TASK_QUEUE_URL = os.environ.get("TASK_QUEUE_URL")
_dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
_sqs = boto3.client("sqs", region_name=AWS_REGION)


def _table():
    if not SESSION_TABLE:
        raise RuntimeError("SESSION_TABLE is not configured")
    return _dynamodb.Table(SESSION_TABLE)


def _json_body(event: dict[str, Any]) -> dict[str, Any]:
    body = event.get("body")
    if not body:
        return {}
    if isinstance(body, dict):
        return body
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return {"raw": body}


def _response(status_code: int, payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def _put_session(connection_id: str, route_key: str, event: dict[str, Any]) -> None:
    _table().put_item(
        Item={
            "SessionID": connection_id,
            "status": "connected",
            "routeKey": route_key,
            "connectedAt": datetime.now(timezone.utc).isoformat(),
            "domainName": event.get("requestContext", {}).get("domainName", ""),
            "stage": event.get("requestContext", {}).get("stage", ""),
        }
    )


def _delete_session(connection_id: str) -> None:
    _table().delete_item(Key={"SessionID": connection_id})


def _enqueue_message(connection_id: str, route_key: str, event: dict[str, Any]) -> None:
    if not TASK_QUEUE_URL:
        raise RuntimeError("TASK_QUEUE_URL is not configured")
    payload = {
        "connectionId": connection_id,
        "routeKey": route_key,
        "body": _json_body(event),
        "requestContext": event.get("requestContext", {}),
        "receivedAt": datetime.now(timezone.utc).isoformat(),
    }
    _sqs.send_message(QueueUrl=TASK_QUEUE_URL, MessageBody=json.dumps(payload))


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    request_context = event.get("requestContext", {})
    route_key = request_context.get("routeKey", "$default")
    connection_id = request_context.get("connectionId", "unknown")
    LOGGER.info("Received route %s for connection %s", route_key, connection_id)
    try:
        if route_key == "$connect":
            _put_session(connection_id, route_key, event)
            return _response(200, {"message": "Connected"})
        if route_key == "$disconnect":
            _delete_session(connection_id)
            return _response(200, {"message": "Disconnected"})
        _enqueue_message(connection_id, route_key, event)
        return _response(200, {"message": "Queued", "connectionId": connection_id})
    except Exception as exc:  # pragma: no cover - Lambda catch-all path
        LOGGER.exception("Failed to process WebSocket event")
        return _response(500, {"error": str(exc), "routeKey": route_key})
