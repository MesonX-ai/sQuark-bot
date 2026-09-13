"""Auth Lambda — custom auth flows for sQuark AI Browser registration, MFA, and activation."""
from __future__ import annotations
import json
import logging
import os
from typing import Any
import boto3
from botocore.exceptions import ClientError

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

AWS_REGION = os.environ.get("AWS_REGION", "us-east-2")
USER_POOL_ID = os.environ.get("USER_POOL_ID")
APP_CLIENT_ID = os.environ.get("APP_CLIENT_ID")
IDENTITY_POOL_ID = os.environ.get("IDENTITY_POOL_ID")

_cognito = boto3.client("cognito-idp", region_name=AWS_REGION)
_cognito_identity = boto3.client("cognito-identity", region_name=AWS_REGION)


def _response(status_code: int, payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def _get_user_by_email(email: str) -> dict[str, Any] | None:
    try:
        resp = _cognito.list_users(
            UserPoolId=USER_POOL_ID,
            Filter=f"email = \"{email}\"",
            Limit=1,
        )
        users = resp.get("Users", [])
        return users[0] if users else None
    except Exception:
        return None


def _get_user_by_phone(phone: str) -> dict[str, Any] | None:
    try:
        resp = _cognito.list_users(
            UserPoolId=USER_POOL_ID,
            Filter=f"phone_number = \"{phone}\"",
            Limit=1,
        )
        users = resp.get("Users", [])
        return users[0] if users else None
    except Exception:
        return None


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    LOGGER.info("Auth request: %s", json.dumps(event)[:500])
    try:
        body = json.loads(event.get("body", "{}"))
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON body"})

    action = body.get("action", "")
    try:
        if action == "register":
            return _register(body)
        elif action == "confirm_signup":
            return _confirm_signup(body)
        elif action == "resend_confirmation":
            return _resend_confirmation(body)
        elif action == "login":
            return _login(body)
        elif action == "respond_to_mfa_challenge":
            return _respond_to_mfa_challenge(body)
        elif action == "setup_mfa":
            return _setup_mfa(body)
        elif action == "get_user":
            return _get_user(body)
        else:
            return _response(400, {"error": f"Unknown action: {action}"})
    except ClientError as exc:
        error_code = exc.response["Error"]["Code"]
        error_message = exc.response["Error"].get("Message", str(exc))
        LOGGER.error("AWS error: %s - %s", error_code, error_message)
        return _response(400, {"error": error_message, "code": error_code})
    except Exception as exc:
        LOGGER.exception("Auth handler failed")
        return _response(500, {"error": str(exc)})


def _register(body: dict[str, Any]) -> dict[str, Any]:
    email = body.get("email", "")
    phone = body.get("phone", "")
    password = body.get("password", "")
    name = body.get("name", "")

    if not email or not phone or not password:
        return _response(400, {"error": "Email, phone, and password are required"})

    if _get_user_by_email(email):
        return _response(409, {"error": "User with this email already exists"})
    if _get_user_by_phone(phone):
        return _response(409, {"error": "User with this phone number already exists"})

    user_attributes = [
        {"Name": "email", "Value": email},
        {"Name": "phone_number", "Value": phone},
        {"Name": "email_verified", "Value": "false"},
        {"Name": "phone_number_verified", "Value": "false"},
    ]
    if name:
        user_attributes.append({"Name": "name", "Value": name})

    resp = _cognito.sign_up(
        ClientId=APP_CLIENT_ID,
        Username=email,
        Password=password,
        UserAttributes=user_attributes,
    )

    return _response(200, {
        "message": "User registered successfully. Please verify your email and phone.",
        "user_id": resp.get("UserSub"),
        "code_delivery_details": resp.get("CodeDeliveryDetails"),
    })


def _confirm_signup(body: dict[str, Any]) -> dict[str, Any]:
    email = body.get("email", "")
    code = body.get("code", "")
    if not email or not code:
        return _response(400, {"error": "Email and confirmation code are required"})

    _cognito.confirm_sign_up(
        ClientId=APP_CLIENT_ID,
        Username=email,
        ConfirmationCode=code,
    )
    return _response(200, {"message": "Account confirmed successfully"})


def _resend_confirmation(body: dict[str, Any]) -> dict[str, Any]:
    email = body.get("email", "")
    if not email:
        return _response(400, {"error": "Email is required"})

    _cognito.resend_confirmation_code(
        ClientId=APP_CLIENT_ID,
        Username=email,
    )
    return _response(200, {"message": "Confirmation code resent"})


def _login(body: dict[str, Any]) -> dict[str, Any]:
    email = body.get("email", "")
    password = body.get("password", "")
    if not email or not password:
        return _response(400, {"error": "Email and password are required"})

    resp = _cognito.initiate_auth(
        ClientId=APP_CLIENT_ID,
        AuthFlow="USER_SRP_AUTH",
        AuthParameters={
            "USERNAME": email,
            "PASSWORD": password,
        },
    )

    auth_result = resp.get("AuthenticationResult", {})
    if auth_result:
        return _response(200, {
            "access_token": auth_result.get("AccessToken"),
            "refresh_token": auth_result.get("RefreshToken"),
            "id_token": auth_result.get("IdToken"),
            "expires_in": auth_result.get("ExpiresIn"),
        })

    challenge_name = resp.get("ChallengeName", "")
    if challenge_name in ("SMS_MFA", "SOFTWARE_TOKEN_MFA"):
        return _response(200, {
            "challenge": challenge_name,
            "session": resp.get("Session"),
            "message": "MFA code required",
        })

    return _response(400, {"error": "Login failed", "response": resp})


def _respond_to_mfa_challenge(body: dict[str, Any]) -> dict[str, Any]:
    email = body.get("email", "")
    mfa_code = body.get("mfa_code", "")
    session = body.get("session", "")
    if not email or not mfa_code or not session:
        return _response(400, {"error": "Email, MFA code, and session are required"})

    resp = _cognito.respond_to_auth_challenge(
        ClientId=APP_CLIENT_ID,
        ChallengeName="SMS_MFA",
        Session=session,
        Username=email,
        ChallengeResponses={
            "SMS_MFA_CODE": mfa_code,
        },
    )

    auth_result = resp.get("AuthenticationResult", {})
    return _response(200, {
        "access_token": auth_result.get("AccessToken"),
        "refresh_token": auth_result.get("RefreshToken"),
        "id_token": auth_result.get("IdToken"),
        "expires_in": auth_result.get("ExpiresIn"),
    })


def _setup_mfa(body: dict[str, Any]) -> dict[str, Any]:
    access_token = body.get("access_token", "")
    mfa_type = body.get("mfa_type", "SMS")
    if not access_token:
        return _response(400, {"error": "Access token is required"})

    if mfa_type == "TOTP":
        resp = _cognito.associate_software_token(AccessToken=access_token)
        return _response(200, {
            "message": "TOTP setup initiated",
            "secret_code": resp.get("SecretCode"),
        })
    else:
        resp = _cognito.get_user(UserPoolId=USER_POOL_ID, AccessToken=access_token)
        phone = ""
        for attr in resp.get("UserAttributes", []):
            if attr["Name"] == "phone_number":
                phone = attr["Value"]
                break
        _cognito.set_user_settings(
            AccessToken=access_token,
            MFAOptions=[
                {"DeliveryMedium": "SMS", "AttributeName": "phone_number"}
            ],
        )
        return _response(200, {"message": "SMS MFA enabled", "phone": phone})


def _get_user(body: dict[str, Any]) -> dict[str, Any]:
    access_token = body.get("access_token", "")
    if not access_token:
        return _response(400, {"error": "Access token is required"})

    resp = _cognito.get_user(UserPoolId=USER_POOL_ID, AccessToken=access_token)
    attributes = {}
    for attr in resp.get("UserAttributes", []):
        attributes[attr["Name"]] = attr["Value"]

    groups = []
    try:
        groups_resp = _cognito.admin_list_groups_for_user(
            Username=resp.get("Username", ""),
            UserPoolId=USER_POOL_ID,
        )
        groups = [g["GroupName"] for g in groups_resp.get("Groups", [])]
    except Exception:
        pass

    return _response(200, {
        "username": resp.get("Username"),
        "attributes": attributes,
        "groups": groups,
    })
