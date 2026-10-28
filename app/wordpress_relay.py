"""Relay for the Portal's calls to its news site (WordPress REST API).

The site's Cloudflare challenges every request from Cloudflare Workers, which is
where the Portal runs, so the Portal sends those calls here and they leave from
the NAS. Only `WORDPRESS_URL/wp-json/...` is reachable, and only with the
packages service token. The Portal sends the site's own sign-in in
`X-Wordpress-Authorization`; Drive never stores it.
"""

from __future__ import annotations

import logging

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response

from config import get_settings
from service_auth import require_service_token

log = logging.getLogger("infocus.wordpress")

WORDPRESS_TIMEOUT = httpx.Timeout(60.0, connect=10.0)
FORWARD_HEADERS = ("accept", "content-type", "content-disposition", "user-agent")

router = APIRouter(prefix="/api/service/wordpress", dependencies=[Depends(require_service_token)])


@router.api_route("/wp-json/{path:path}", methods=["GET", "POST"])
async def relay(path: str, request: Request) -> Response:
    base = (get_settings().wordpress_url or "").strip().rstrip("/")
    if not base.startswith("https://"):
        raise HTTPException(status_code=503, detail="WORDPRESS_URL not configured on drive")
    if any(part in ("..", ".") for part in path.split("/")):
        raise HTTPException(status_code=400, detail="Invalid path")
    authorization = request.headers.get("x-wordpress-authorization")
    if not authorization:
        raise HTTPException(status_code=400, detail="Missing X-Wordpress-Authorization")
    headers = {name: value for name in FORWARD_HEADERS if (value := request.headers.get(name))}
    headers["authorization"] = authorization
    url = f"{base}/wp-json/{path}"
    if request.url.query:
        url += f"?{request.url.query}"
    try:
        async with httpx.AsyncClient(timeout=WORDPRESS_TIMEOUT) as client:
            resp = await client.request(request.method, url, content=await request.body(), headers=headers)
    except httpx.HTTPError as e:
        log.warning("wordpress unreachable: %s", type(e).__name__)
        raise HTTPException(status_code=502, detail="WordPress site unreachable from drive") from e
    return Response(resp.content, status_code=resp.status_code, media_type=resp.headers.get("content-type"))
