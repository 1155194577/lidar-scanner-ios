#!/usr/bin/env python3
"""Local stand-in for the print endpoint, for development and UI tests.

Mirrors the live contract: POST /print takes multipart form data with either
`mesh` (an .obj, .ply or .usdz file in metres) or `photo` (.jpg/.png) plus an
optional `height_mm`, or `mode=face` with a front-camera `photo`, `intrinsics`,
`camera_transform`, `image_orientation`, optional `depth` (float32 metres) with
`depth_width`/`depth_height`/`depth_intrinsics`/`depth_extrinsics`, `face_transform`,
`face_vertices` (float32 xyz) with `face_vertex_count` and `height_mm`. It answers with a small STL cube as `model/stl` and an
`X-Print-Report` JSON header. Errors are JSON `{"detail": ...}`. With --token,
requests must carry `Authorization: Bearer <token>` or get a 401. GET /last returns a JSON summary of the
last accepted print request, for UI tests.

    python3 scripts/print_stub.py            # listens on 0.0.0.0:8765
    python3 scripts/print_stub.py --port 9000 --delay 2 --token secret
"""
import argparse
import email.parser
import email.policy
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MESH_EXTENSIONS = (".obj", ".ply", ".usdz")
PHOTO_EXTENSIONS = (".jpg", ".jpeg", ".png")
MAX_UPLOAD_BYTES = 200 * 1024 * 1024


def cube_stl(size_mm=20.0):
    s = size_mm
    v = [(x * s, y * s, z * s) for x in (0, 1) for y in (0, 1) for z in (0, 1)]
    faces = [
        ((-1, 0, 0), (0, 1, 3), (0, 3, 2)), ((1, 0, 0), (4, 6, 7), (4, 7, 5)),
        ((0, -1, 0), (0, 4, 5), (0, 5, 1)), ((0, 1, 0), (2, 3, 7), (2, 7, 6)),
        ((0, 0, -1), (0, 2, 6), (0, 6, 4)), ((0, 0, 1), (1, 5, 7), (1, 7, 3)),
    ]
    lines = ["solid stub_cube"]
    for normal, *tris in faces:
        for tri in tris:
            lines.append("  facet normal %g %g %g" % normal)
            lines.append("    outer loop")
            lines.extend("      vertex %g %g %g" % v[i] for i in tri)
            lines.append("    endloop")
            lines.append("  endfacet")
    lines.append("endsolid stub_cube")
    return ("\n".join(lines) + "\n").encode()


def parse_multipart(content_type, body):
    message = email.parser.BytesParser(policy=email.policy.default).parsebytes(
        b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body
    )
    if not message.is_multipart():
        return {}
    parts = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name:
            parts[name] = (part.get_filename(), part.get_payload(decode=True) or b"")
    return parts


def check_face(parts):
    """Validates the `mode=face` fields and returns a summary of them."""
    def text(name):
        return parts[name][1].decode() if name in parts else None

    def matrix(name, size=16):
        value = json.loads(text(name)) if name in parts else None
        if value is not None and (not isinstance(value, list) or len(value) != size):
            raise ValueError("%s must be %d numbers" % (name, size))
        return value

    def intrinsics(name):
        value = json.loads(text(name)) if name in parts else None
        if value is not None and not (isinstance(value, dict) and all(k in value for k in ("fx", "fy", "cx", "cy", "width", "height"))):
            raise ValueError("%s must have fx, fy, cx, cy, width and height" % name)
        return value

    try:
        summary = {
            "mode": "face",
            "image_orientation": int(text("image_orientation") or 1),
            "intrinsics": intrinsics("intrinsics"),
            "camera_transform": matrix("camera_transform"),
            "face_transform": matrix("face_transform"),
            "depth_intrinsics": intrinsics("depth_intrinsics"),
            "depth_extrinsics": matrix("depth_extrinsics"),
            "height_mm": float(text("height_mm") or 100),
        }
        if "depth" in parts:
            width, height = int(text("depth_width")), int(text("depth_height"))
            if width <= 0 or height <= 0 or len(parts["depth"][1]) != width * height * 4:
                raise ValueError("depth must be depth_width x depth_height float32 values")
            summary.update(depth_width=width, depth_height=height)
        if "face_vertices" in parts:
            count = int(text("face_vertex_count"))
            if count <= 0 or len(parts["face_vertices"][1]) != count * 12:
                raise ValueError("face_vertices must be face_vertex_count x 3 float32 values")
            summary["face_vertex_count"] = count
    except (TypeError, ValueError) as error:
        raise ValueError(str(error) if str(error).startswith(("depth", "face", "camera", "intrinsics")) else "face fields must be numbers or JSON")
    if summary["image_orientation"] not in (1, 3, 6, 8):
        raise ValueError("image_orientation must be 1, 3, 6 or 8")
    if summary["height_mm"] <= 0:
        raise ValueError("height_mm must be a positive number")
    return summary


class Handler(BaseHTTPRequestHandler):
    delay = 0.0
    token = None
    timeout = 60
    last_request = {}

    def do_GET(self):
        if self.path.rstrip("/") == "/health":
            self.reply(200, "text/plain", b"ok\n")
        elif self.path.rstrip("/") == "/last":
            self.reply(200, "application/json", json.dumps(Handler.last_request).encode())
        else:
            self.reply(404, "text/plain", b"not found\n")

    def do_POST(self):
        if self.path.rstrip("/") != "/print":
            return self.error(404, "not found")
        if self.token and self.headers.get("Authorization") != "Bearer " + self.token:
            self.close_connection = True
            return self.error(401, "missing or invalid token")
        content_type = self.headers.get("Content-Type", "")
        if not content_type.startswith("multipart/form-data"):
            return self.error(400, "expected multipart/form-data")
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self.error(411, "Content-Length required")
        if length < 0 or length > MAX_UPLOAD_BYTES:
            self.close_connection = True
            return self.error(413, "upload larger than %d MB" % (MAX_UPLOAD_BYTES // (1024 * 1024)))
        body = self.rfile.read(length)
        parts = parse_multipart(content_type, body)

        if ("mesh" in parts) == ("photo" in parts):
            return self.error(400, "send exactly one of mesh or photo")
        if "mesh" in parts:
            filename, data = parts["mesh"]
            if not filename or not filename.lower().endswith(MESH_EXTENSIONS):
                return self.error(415, "mesh must be an .obj, .ply or .usdz file")
            if not data:
                return self.error(400, "mesh is empty")
            source = "mesh %s (%d bytes)" % (filename, len(data))
            stem = filename.rsplit(".", 1)[0]
        else:
            filename, data = parts["photo"]
            if not filename or not filename.lower().endswith(PHOTO_EXTENSIONS):
                return self.error(415, "photo must be a .jpg or .png file")
            if not data:
                return self.error(400, "photo is empty")
            source = "photo (%d bytes)" % len(data)
            if "height_mm" in parts:
                try:
                    height = float(parts["height_mm"][1].decode())
                except ValueError:
                    height = 0
                if height <= 0:
                    return self.error(422, "height_mm must be a positive number")
                source += ", height %g mm" % height
            stem = "photo"
            summary = {}
            if parts.get("mode", (None, b"object"))[1].decode() == "face":
                try:
                    summary = check_face(parts)
                except ValueError as error:
                    return self.error(422, str(error))
                source = source.replace("photo", "face photo", 1)
                if "depth_width" in summary:
                    source += ", depth %(depth_width)dx%(depth_height)d" % summary
                stem = "face"

        Handler.last_request = {"fields": sorted(parts), "source": source}
        if "photo" in parts:
            Handler.last_request.update(summary)
        self.log_message("print request: %s", source)
        time.sleep(self.delay)
        report = {"extents_mm": [20.0, 20.0, 20.0], "watertight": True, "volume_cm3": 8.0}
        self.reply(200, "model/stl", cube_stl(), {
            "Content-Disposition": 'attachment; filename="%s.stl"' % stem,
            "X-Print-Report": json.dumps(report),
        })

    def error(self, status, detail):
        self.reply(status, "application/json", json.dumps({"detail": detail}).encode())

    def reply(self, status, content_type, body, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--delay", type=float, default=0.0, help="seconds to wait before answering")
    parser.add_argument("--token", help="require Authorization: Bearer <token>")
    args = parser.parse_args()
    Handler.delay = args.delay
    Handler.token = args.token
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print("Print stub listening on http://%s:%d/print" % (args.host, args.port), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
