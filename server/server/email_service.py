"""Transactional email delivery for account verification."""

import asyncio
import smtplib
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid

from .config import (
    EMAIL_DELIVERY_ENABLED,
    SMTP_FROM_EMAIL,
    SMTP_FROM_NAME,
    SMTP_HOST,
    SMTP_PASSWORD,
    SMTP_PORT,
    SMTP_USERNAME,
    SMTP_USE_SSL,
    SMTP_USE_TLS,
)


class EmailDeliveryUnavailable(RuntimeError):
    pass


async def send_verification_email(email: str, code: str, purpose: str) -> None:
    if not EMAIL_DELIVERY_ENABLED:
        raise EmailDeliveryUnavailable("SMTP is not configured")
    await asyncio.to_thread(_send_verification_email_sync, email, code, purpose)


def _send_verification_email_sync(email: str, code: str, purpose: str) -> None:
    action = "重置密码" if purpose == "reset_password" else "注册账号"
    message = EmailMessage()
    message["Subject"] = f"{code} · Zeluna {action}验证码"
    message["From"] = formataddr((SMTP_FROM_NAME, SMTP_FROM_EMAIL))
    message["To"] = email
    message["Date"] = formatdate(localtime=False)
    from_domain = SMTP_FROM_EMAIL.rpartition("@")[2] or None
    message["Message-ID"] = make_msgid(domain=from_domain)
    message.set_content(
        f"你正在使用此邮箱{action}。\n\n"
        f"验证码：{code}\n\n"
        "验证码 10 分钟内有效。若不是你本人操作，请忽略此邮件。"
    )

    smtp_type = smtplib.SMTP_SSL if SMTP_USE_SSL else smtplib.SMTP
    with smtp_type(SMTP_HOST, SMTP_PORT, timeout=15) as smtp:
        if not SMTP_USE_SSL:
            smtp.ehlo()
            if SMTP_USE_TLS:
                smtp.starttls()
                smtp.ehlo()
        if SMTP_USERNAME:
            smtp.login(SMTP_USERNAME, SMTP_PASSWORD)
        smtp.send_message(message)
